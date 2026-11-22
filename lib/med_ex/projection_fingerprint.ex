defmodule MedEx.ProjectionFingerprint do
  @moduledoc false

  @projection_dir "dist/monolith/med_ex"
  @fingerprint_file ".med_ex_input_fingerprint"

  @spec compute(String.t()) :: %{
          input_sha256: String.t(),
          file_count: non_neg_integer(),
          git_head: String.t()
        }
  def compute(root \\ File.cwd!()) do
    files = tracked_input_files(root)

    hasher =
      Enum.reduce(files, :crypto.hash_init(:sha256), fn rel_path, acc ->
        full_path = Path.join(root, rel_path)
        content = File.read!(full_path)

        acc
        |> :crypto.hash_update(rel_path)
        |> :crypto.hash_update(<<0>>)
        |> :crypto.hash_update(content)
        |> :crypto.hash_update(<<0>>)
      end)

    %{
      input_sha256: hasher |> :crypto.hash_final() |> Base.encode16(case: :lower),
      file_count: length(files),
      git_head: git_head(root)
    }
  end

  @spec write!(String.t()) :: %{
          input_sha256: String.t(),
          file_count: non_neg_integer(),
          git_head: String.t(),
          recorded_at: String.t()
        }
  def write!(root \\ File.cwd!()) do
    info = Map.put(compute(root), :recorded_at, DateTime.utc_now() |> DateTime.to_iso8601())
    path = fingerprint_path(root)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(info, pretty: true) <> "\n")
    info
  end

  @spec status(String.t()) :: %{
          status: :fresh | :stale | :missing,
          current: map(),
          recorded: map() | nil,
          projection_lock_present?: boolean()
        }
  def status(root \\ File.cwd!()) do
    current = compute(root)
    lock_present? = File.regular?(Path.join([root, @projection_dir, "projection.lock.json"]))
    fp_path = fingerprint_path(root)

    case {lock_present?, File.read(fp_path)} do
      {true, {:ok, raw}} ->
        recorded = Jason.decode!(raw)

        status =
          if recorded["input_sha256"] == current.input_sha256, do: :fresh, else: :stale

        %{
          status: status,
          current: current,
          recorded: recorded,
          projection_lock_present?: true
        }

      _ ->
        %{
          status: :missing,
          current: current,
          recorded: nil,
          projection_lock_present?: lock_present?
        }
    end
  end

  defp fingerprint_path(root), do: Path.join([root, @projection_dir, @fingerprint_file])

  defp tracked_input_files(root) do
    globs = [
      "build_support/weld.exs",
      "README.md",
      "CHANGELOG.md",
      "LICENSE",
      "assets/med_ex.svg",
      "core/med_core/{mix.exs,mix.lock,README.md,CHANGELOG.md,LICENSE}",
      "core/med_core/{lib,test,config,priv}/**/*",
      "core/med_rtc/{mix.exs,mix.lock,README.md,CHANGELOG.md,LICENSE}",
      "core/med_rtc/{lib,test,config,priv}/**/*",
      "core/med_web/{mix.exs,mix.lock,README.md,CHANGELOG.md,LICENSE}",
      "core/med_web/{lib,test,config,priv}/**/*"
    ]

    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp git_head(root) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: root, stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end
