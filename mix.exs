defmodule MedEx.MixProject do
  use Mix.Project
  @composition elem(Code.eval_file("build_support/composition.exs", __DIR__), 0)
  @package @composition.package
  @sources Enum.map(@composition.components, &Path.join(&1, "lib"))
  @test_paths ["test" | Enum.map(@composition.components, &Path.join(&1, "test"))]
  @files @sources ++
           @composition.documents ++
           @composition.assets ++
           [@composition.version_file, "mix.exs", "build_support/composition.exs"]

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

  defp docs_diagrams(:html) do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@11.12.2/dist/mermaid.min.js"></script>
    <script>
      document.addEventListener("DOMContentLoaded", () => {
        const codeBlocks = document.querySelectorAll("pre code.mermaid");
        if (!codeBlocks.length || !window.mermaid) return;
        mermaid.initialize({startOnLoad: false, securityLevel: "strict"});
        const nodes = Array.from(codeBlocks, code => {
          const diagram = document.createElement("div");
          diagram.className = "mermaid";
          diagram.textContent = code.textContent;
          code.parentElement.replaceWith(diagram);
          return diagram;
        });
        mermaid.run({nodes});
      });
    </script>
    """
  end

  defp docs_diagrams(_format), do: ""
end
