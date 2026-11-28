defmodule MedEx.Build.QualificationReceipt do
  @moduledoc false

  def fingerprint(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  def read(path, input, files) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, %{"payload" => payload, "sha256" => checksum}} <- JSON.decode(bytes),
         %{"schema" => 1, "input" => ^input, "files" => recorded, "details" => details} <- payload,
         ^checksum <- fingerprint(payload),
         {:ok, ^recorded} <- digests(files) do
      {:ok, details}
    else
      _ -> :miss
    end
  end

  def write!(path, input, files, details) do
    outputs =
      case digests(files) do
        {:ok, outputs} ->
          outputs

        {:error, {path, reason}} ->
          raise "Cannot record qualification output #{path}: #{inspect(reason)}"
      end

    payload = %{"schema" => 1, "input" => input, "files" => outputs, "details" => details}
    bytes = JSON.encode_to_iodata!(%{payload: payload, sha256: fingerprint(payload)})
    temporary = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    File.mkdir_p!(Path.dirname(path))

    try do
      File.write!(temporary, bytes, [:exclusive, :sync])
      File.chmod!(temporary, 0o600)
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  def digests(files) do
    Enum.reduce_while(files, {:ok, %{}}, fn {name, path}, {:ok, acc} ->
      with {:ok, %{type: :regular}} <- File.lstat(path),
           {:ok, bytes} <- File.read(path) do
        {:cont, {:ok, Map.put(acc, name, sha256(bytes))}}
      else
        {:ok, %{type: type}} -> {:halt, {:error, {path, {:not_regular, type}}}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
  end

  # Only retained proof inputs and reports belong in a native receipt. The
  # consumer trees contain generated dependencies, build products and links.
  # Enumerate required files even when absent, so missing proof fails closed.
  def native_outputs(directory, gate)
      when gate in ~w(fabric-native fabric-soak-off fabric-soak-isolated) do
    common = ~w(exit-status run.log native.json) ++ role_outputs("installed")

    specific =
      if gate == "fabric-native" do
        ["detached.json" | role_outputs("detached.json.inputs")] ++
          ~w(detached.json.inputs/combined-installed.json detached.json.inputs/combined-mix.lock detached.json.inputs/combined-tests.log)
      else
        ["filesystem.txt"]
      end

    Enum.map(common ++ specific, &Path.join(directory, &1))
  end

  defp role_outputs(directory) do
    roles =
      for role <- ~w(exam handheld preview),
          suffix <- ~w(installed.json mix.lock dependencies.txt) do
        role <> "-" <> suffix
      end

    Enum.map(~w(artifacts.json registry.json) ++ roles, &Path.join(directory, &1))
  end

  def sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  def toolchain do
    otp = :erlang.system_info(:otp_release)
    version = Path.join([to_string(:code.root_dir()), "releases", to_string(otp), "OTP_VERSION"])

    {
      System.version(),
      File.read(version),
      :erlang.system_info(:system_architecture),
      :os.type(),
      Enum.map(
        ~w(CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ERL_FLAGS MIX_TARGET),
        &System.get_env/1
      )
    }
  end

  def git!(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {value, 0} -> value
      {message, status} -> raise "Git inspection failed (#{status}) in #{root}: #{message}"
    end
  end

  def source(root, pathspecs \\ []) do
    files =
      git!(root, [
        "ls-files",
        "-z",
        "--cached",
        "--others",
        "--exclude-standard",
        "--" | pathspecs
      ])
      |> String.split(<<0>>, trim: true)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(files, fn path ->
      full_path = Path.join(root, path)

      case File.lstat(full_path) do
        {:ok, %{type: :regular, mode: mode}} ->
          {path, Bitwise.band(mode, 0o111), full_path |> File.read!() |> sha256()}

        {:ok, %{type: :symlink}} ->
          {path, File.read_link!(full_path), File.read(full_path)}

        {:error, :enoent} ->
          {path, :missing}

        other ->
          raise "cannot fingerprint #{path}: #{inspect(other)}"
      end
    end)
  end
end
