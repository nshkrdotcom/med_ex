defmodule MedEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_ex,
      version: "0.4.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: erlc_paths(Mix.env()),
      erlc_options: erlc_options(Mix.env()),
      test_paths: [
        "components/core/med_core/test",
        "components/core/med_capture/test",
        "test/artifact_1"
      ],
      test_ignore_filters: [],
      build_path: "_build",
      deps: deps(),
      description: "Source-preserving waveform and measurement acquisition",
      package: package(),
      docs: docs()
    ]
  end

  def application, do: [extra_applications: [:crypto, :logger]]

  def elixirc_paths(:test),
    do: ["config", "components/core/med_capture/lib", "components/core/med_core/lib"]

  def elixirc_paths(_),
    do: ["config", "components/core/med_capture/lib", "components/core/med_core/lib"]

  def erlc_paths(:test), do: ["components/core/med_capture/src", "components/core/med_core/src"]
  def erlc_paths(_), do: ["components/core/med_capture/src", "components/core/med_core/src"]

  defp erlc_options(env) do
    paths = if env == :test, do: [], else: []
    Enum.map(paths, &{:i, &1 |> Path.expand(__DIR__) |> String.to_charlist()})
  end

  defp deps,
    do: [
      {:credo, "~> 1.7", [only: [:dev, :test], runtime: false]},
      {:dialyxir, "~> 1.4", [only: [:dev], runtime: false]},
      {:ex_doc, "~> 0.40.5", [only: [:dev], runtime: false]}
    ]

  defp package do
    [
      name: "med_ex",
      licenses: ["MIT"],
      links: %{"Source" => "https://github.com/nshkrdotcom/med_ex"},
      files: [
        ".credo.exs",
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "assets/med_ex.svg",
        "components/core/med_capture/lib/med_ex/storage.ex",
        "components/core/med_capture/lib/med_ex/storage/effective_uid.ex",
        "components/core/med_capture/lib/med_ex/storage/file.ex",
        "components/core/med_capture/lib/med_ex/storage/journal.ex",
        "components/core/med_capture/lib/med_ex/storage/objects.ex",
        "components/core/med_capture/lib/med_ex/storage/records.ex",
        "components/core/med_capture/lib/med_ex/stream_writer.ex",
        "components/core/med_core/lib/med_ex/canonical_json.ex",
        "components/core/med_core/lib/med_ex/clock_align.ex",
        "components/core/med_core/lib/med_ex/contract.ex",
        "components/core/med_core/lib/med_ex/contract_rules.ex",
        "components/core/med_core/lib/med_ex/control_interlock.ex",
        "components/core/med_core/lib/med_ex/format/wav.ex",
        "components/core/med_core/lib/med_ex/frame_fingerprint.ex",
        "components/core/med_core/lib/med_ex/integrity_span.ex",
        "components/core/med_core/lib/med_ex/measurement_event.ex",
        "components/core/med_core/lib/med_ex/receipt.ex",
        "components/core/med_core/lib/med_ex/recording_limits.ex",
        "components/core/med_core/lib/med_ex/sample_frame.ex",
        "components/core/med_core/lib/med_ex/segment_ref.ex",
        "components/core/med_core/lib/med_ex/serialization.ex",
        "components/core/med_core/lib/med_ex/status_event.ex",
        "components/core/med_core/lib/med_ex/stream_cursor.ex",
        "components/core/med_core/lib/med_ex/stream_index.ex",
        "components/core/med_core/lib/med_ex/stream_spec.ex",
        "components/core/med_core/lib/med_ex/wire/control.ex",
        "components/core/med_core/lib/med_ex/wire/credit.ex",
        "components/core/med_core/lib/med_ex/wire/frame_v1.ex",
        "config/config.exs",
        "config/dev.exs",
        "config/prod.exs",
        "config/test.exs",
        "guides/architecture_and_roadmap.md",
        "guides/durability_and_guarantees.md",
        "guides/host_integration.md",
        "guides/product_horizon.md",
        "guides/releasing.md",
        "guides/source_development.md",
        "guides/stream_recording.md",
        "guides/technical_contract.md",
        "mix.exs"
      ]
    ]
  end

  defp docs,
    do:
      Keyword.put(
        [
          groups_for_extras: [
            {"Overview", ["README.md", "guides/architecture_and_roadmap.md"]},
            {"Integration Guides",
             [
               "guides/stream_recording.md",
               "guides/durability_and_guarantees.md",
               "guides/technical_contract.md",
               "guides/host_integration.md",
               "guides/source_development.md",
               "guides/releasing.md"
             ]},
            {"Horizon", ["guides/product_horizon.md"]},
            {"Release", ["CHANGELOG.md", "LICENSE"]}
          ],
          assets: %{"assets" => "assets"},
          source_ref: "med_ex-v0.4.0",
          source_url: "https://github.com/nshkrdotcom/med_ex",
          logo: "assets/med_ex.svg",
          main: "readme",
          extras: [
            {"CHANGELOG.md", [title: "Changelog"]},
            {"LICENSE", [title: "License"]},
            {"README.md", [title: "Overview"]},
            {"guides/architecture_and_roadmap.md", [title: "Architecture and Composition"]},
            {"guides/durability_and_guarantees.md",
             [title: "Durability and Ordering Guarantees"]},
            {"guides/host_integration.md", [title: "Host Integration and Root Ownership"]},
            {"guides/product_horizon.md", [title: "Medical-Device Product Horizon"]},
            {"guides/releasing.md", [title: "Coordinated Release"]},
            {"guides/source_development.md",
             [title: "Consumption, Extensions, and Verification"]},
            {"guides/stream_recording.md", [title: "Streams, Storage, Clock, and Control"]},
            {"guides/technical_contract.md", [title: "Technical Contract and Revision 2"]}
          ]
        ],
        :before_closing_body_tag,
        fn
          :html ->
            "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@11.12.2/dist/mermaid.min.js\"></script>\n<script>\nwindow.addEventListener(\"exdoc:loaded\", () => {\nconst codeBlocks = document.querySelectorAll(\"pre code.mermaid\");\nif (!codeBlocks.length || !window.mermaid) return;\nmermaid.initialize({\nstartOnLoad: false,\nsecurityLevel: \"strict\",\ntheme: document.body.classList.contains(\"dark\") ? \"dark\" : \"default\"\n});\nconst nodes = Array.from(codeBlocks, code => {\nconst diagram = document.createElement(\"div\");\ndiagram.className = \"mermaid\";\ndiagram.textContent = code.textContent;\ncode.parentElement.replaceWith(diagram);\nreturn diagram;\n});\nmermaid.run({nodes});\n});\n</script>\n"

          _ ->
            ""
        end
      )
end
