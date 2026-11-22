defmodule Mix.Tasks.MedEx.Projection.Status do
  @moduledoc """
  Reports whether `dist/monolith/med_ex` matches the current MedEx source inputs.

  Pass `--strict` to exit non-zero when the local projection is missing or stale.
  """

  @shortdoc "Check freshness and provenance of the local :med_ex Weld projection"

  use Mix.Task

  alias MedEx.ProjectionFingerprint

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [strict: :boolean])
    info = ProjectionFingerprint.status()

    Mix.shell().info("projection_status: #{info.status}")
    Mix.shell().info("current_input_sha256: #{info.current.input_sha256}")
    Mix.shell().info("current_git_head: #{info.current.git_head}")
    Mix.shell().info("input_file_count: #{info.current.file_count}")
    Mix.shell().info("projection_lock_present: #{info.projection_lock_present?}")

    if info.recorded do
      Mix.shell().info("recorded_input_sha256: #{info.recorded["input_sha256"]}")
      Mix.shell().info("recorded_git_head: #{info.recorded["git_head"]}")
      Mix.shell().info("recorded_at: #{info.recorded["recorded_at"]}")
    end

    if Keyword.get(opts, :strict, false) and info.status != :fresh do
      Mix.raise(
        "Local :med_ex projection is #{info.status}. Run `mix med_ex.projection.refresh` before running downstream local checks."
      )
    end
  end
end
