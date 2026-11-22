defmodule Mix.Tasks.MedEx.Projection.Refresh do
  @moduledoc """
  Canonical entry point to re-project `dist/monolith/med_ex` via Weld and
  record its verified input provenance fingerprint.

  Computes the input fingerprint before and after `mix weld.project` and fails
  closed if any tracked source input changed mid-generation.
  """

  @shortdoc "Refresh the local :med_ex Weld projection and record its input fingerprint"

  use Mix.Task

  alias MedEx.ProjectionFingerprint

  @impl Mix.Task
  def run(_args) do
    before_fp = ProjectionFingerprint.compute()
    t0 = System.monotonic_time(:millisecond)

    Mix.Task.reenable("weld.project")
    Mix.Task.run("weld.project", [])

    after_fp = ProjectionFingerprint.compute()

    if before_fp.input_sha256 != after_fp.input_sha256 do
      Mix.raise(
        "MedEx projection inputs changed during `mix weld.project` (#{before_fp.input_sha256} -> #{after_fp.input_sha256}). Re-run `mix med_ex.projection.refresh`."
      )
    end

    info = ProjectionFingerprint.write!(after_fp)
    elapsed_ms = System.monotonic_time(:millisecond) - t0

    Mix.shell().info(
      "Refreshed :med_ex projection in #{elapsed_ms}ms (input_sha256=#{info.input_sha256}, files=#{info.file_count}, weld=#{info.weld_version}, head=#{info.git_head})"
    )
  end
end
