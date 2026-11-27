workspace = Path.join(__DIR__, "build_support/workspace.exs")
if File.regular?(workspace), do: Code.require_file(workspace)

defmodule MedEx.MixProject do
  use Mix.Project
  alias MedEx.Build.Workspace
  @compile {:no_warn_undefined, Workspace}
  @workspace File.regular?(Path.join(__DIR__, "build_support/workspace.exs"))
  @composition elem(Code.eval_file("build_support/composition.exs", __DIR__), 0)
  @package @composition.package
  @sources Enum.map(@composition.components, &Path.join(&1, "lib"))
  @test_paths ["test" | Enum.map(@composition.components, &Path.join(&1, "test"))]
  @files @sources ++
           @composition.documents ++
           @composition.assets ++
           [
             @composition.version_file,
             "mix.exs",
             "build_support/composition.exs",
             @package[:docs][:hook_file]
           ]

  def project do
    [
      app: :med_ex,
      version: @package[:version],
      elixir: @package[:elixir],
      deps: @package[:development_dependencies] ++ workspace_dependencies(),
      aliases: if(@workspace, do: Workspace.aliases(), else: []),
      docs: docs(),
      description: @package[:description],
      elixirc_paths: @sources,
      test_paths: @test_paths,
      test_ignore_filters:
        ~w(test/test_helper.exs test/projection/test_helper.exs) ++
          Enum.map(@composition.components, &Path.join(&1, "test/test_helper.exs")) ++
          ["core/med_capture/test/support/fixture_helper.exs"],
      package: Keyword.take(@package, [:licenses, :links]) ++ [files: @files]
    ]
  end

  def cli,
    do: [
      preferred_envs: [
        setup: :dev,
        test: :dev,
        credo: :dev,
        dialyzer: :dev,
        quality: :dev,
        docs: :dev
      ]
    ]

  defp workspace_dependencies do
    if @workspace, do: [{:blitz, "0.4.1", only: [:dev, :test], runtime: false}], else: []
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp docs do
    Keyword.take(@package[:docs], [:main, :logo, :assets, :source_url, :groups_for_extras]) ++
      [
        name: "MedEx",
        before_closing_body_tag: &docs_diagrams/1,
        extras: Enum.map(@composition.extras, fn {file, title} -> {file, [title: title]} end),
        groups_for_modules: [
          "Stream and Event Contracts": [
            MedEx.Contract,
            MedEx.Receipt,
            MedEx.RecordingLimits,
            MedEx.StreamSpec,
            MedEx.SampleFrame,
            MedEx.FrameFingerprint,
            MedEx.MeasurementEvent,
            MedEx.StatusEvent,
            MedEx.IntegritySpan,
            MedEx.SegmentRef,
            MedEx.StreamCursor,
            MedEx.StreamIndex
          ],
          "Framing, Serialization, Clock, and Control": [
            MedEx.Wire.FrameV1,
            MedEx.Wire.Control,
            MedEx.Wire.Credit,
            MedEx.Serialization,
            MedEx.CanonicalJSON,
            MedEx.ClockAlign,
            MedEx.ControlInterlock,
            MedEx.ContractRules
          ],
          "Authoritative Stream Recording": [
            MedEx.StreamWriter,
            MedEx.Storage.File
          ],
          "Validated Playback Projection": [MedEx.Format.Wav]
        ]
      ]
  end

  # One checked-in file owns the hook; Weld embeds the same file in projections.
  defp docs_diagrams(:html), do: File.read!(Path.join(__DIR__, @package[:docs][:hook_file]))

  defp docs_diagrams(_format), do: ""
end
