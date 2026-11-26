defmodule MedEx.MixProject do
  use Mix.Project
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
      deps: @package[:development_dependencies],
      docs: docs(),
      description: @package[:description],
      elixirc_paths: @sources,
      test_paths: @test_paths,
      package: Keyword.take(@package, [:licenses, :links]) ++ [files: @files]
    ]
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
            MedEx.Serialization,
            MedEx.CanonicalJSON,
            MedEx.ClockAlign,
            MedEx.ControlInterlock,
            MedEx.ContractRules
          ],
          "Authoritative Stream Recording": [
            MedEx.StreamWriter,
            MedEx.Storage,
            MedEx.Storage.File
          ],
          "Browser WAV Capture and Media Ports": [
            MedEx.Capture,
            MedEx.Evidence,
            MedEx.Wav,
            MedEx.Format.Wav,
            MedEx.Web,
            MedEx.Preview,
            MedEx.Preview.Clock,
            MedEx.PreviewProvider,
            MedEx.RTCProvider
          ]
        ]
      ]
  end

  # One checked-in file owns the hook; Weld embeds the same file in projections.
  defp docs_diagrams(:html), do: File.read!(Path.join(__DIR__, @package[:docs][:hook_file]))

  defp docs_diagrams(_format), do: ""
end
