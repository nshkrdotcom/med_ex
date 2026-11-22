defmodule Mix.Tasks.MedEx.Projection.Refresh do
  @moduledoc """
  Re-projects `dist/monolith/med_ex` via Weld and writes an input provenance fingerprint.
  """

  @shortdoc "Refresh the local :med_ex Weld projection and record its input fingerprint"

  use Mix.Task

  alias MedEx.ProjectionFingerprint

  @impl Mix.Task
  def run(_args) do
    t0 = System.monotonic_time(:millisecond)
    Mix.Task.reenable("weld.project")
    Mix.Task.run("weld.project", [])
    info = ProjectionFingerprint.write!()
    elapsed_ms = System.monotonic_time(:millisecond) - t0

    Mix.shell().info(
      "Refreshed :med_ex projection in #{elapsed_ms}ms (input_sha256=#{info.input_sha256}, files=#{info.file_count}, head=#{info.git_head})"
    )
  end
end
