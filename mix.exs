defmodule MedEx.MixProject do
  use Mix.Project
  @version File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()
  @sources ~w(core/med_core/lib core/med_capture/lib)
  def project do
    [
      app: :med_ex,
      version: @version,
      elixir: "~> 1.20",
      deps: [{:ex_doc, "~> 0.40.5", only: :dev, runtime: false}],
      docs: docs(),
      description: "Source-preserving waveform and measurement acquisition",
      elixirc_paths: @sources,
      test_paths: ~w(test core/med_core/test core/med_capture/test),
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://github.com/nshkrdotcom/med_ex"},
        files: @sources ++ ~w(mix.exs VERSION priv guides assets LICENSE README.md CHANGELOG.md)
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp docs do
    [
      name: "MedEx",
      main: "readme",
      logo: "assets/med_ex.svg",
      assets: %{"assets" => "assets"},
      source_url: "https://github.com/nshkrdotcom/med_ex",
      before_closing_body_tag: &docs_diagrams/1,
      extras: [
        "README.md": [title: "Overview"],
        "guides/architecture_and_roadmap.md": [title: "Architecture and Composition"],
        "guides/stream_recording.md": [title: "Streams, Storage, Clock, and Control"],
        "guides/host_integration.md": [title: "Host Integration and Browser Compatibility"],
        "guides/source_development.md": [title: "Consumption, Extensions, and Verification"],
        "guides/product_horizon.md": [title: "Medical-Device Product Horizon"],
        "CHANGELOG.md": [title: "Changelog"],
        "guides/history/med_rtc_changelog.md": [title: "Historical MedRTC Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_extras: [
        Overview: ~r/README\.md|guides\/architecture_and_roadmap\.md/,
        "Integration Guides":
          ~r/guides\/stream_recording\.md|guides\/host_integration\.md|guides\/source_development\.md/,
        Horizon: ~r/guides\/product_horizon\.md/,
        Release: ~r/CHANGELOG\.md|guides\/history\/med_rtc_changelog\.md|LICENSE/
      ],
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
