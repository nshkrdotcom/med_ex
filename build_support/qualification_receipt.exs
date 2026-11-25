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
    {:ok, outputs} = digests(files)
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
        _ -> {:halt, :missing}
      end
    end)
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
