defmodule MedEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_ex,
      version: "0.3.0",
      build_path: "_build",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: erlc_paths(Mix.env()),
      erlc_options: erlc_options(Mix.env()),
      test_paths: [
        "components/core/med_capture/test",
        "components/core/med_core/test",
        "test/artifact_1"
      ],
      deps: deps(),
      description: "Source-preserving waveform and measurement acquisition",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  def elixirc_paths(:test) do
    base = ["config", "components/core/med_capture/lib", "components/core/med_core/lib"]

    if File.dir?(Path.expand("test/support", __DIR__)) do
      base ++ ["test/support"]
    else
      base
    end
  end

  def elixirc_paths(_env),
    do: ["config", "components/core/med_capture/lib", "components/core/med_core/lib"]

  defp erlc_paths(:test), do: ["components/core/med_capture/src", "components/core/med_core/src"]
  defp erlc_paths(_env), do: ["components/core/med_capture/src", "components/core/med_core/src"]

  defp erlc_options(env) do
    paths = if env == :test, do: [], else: []
    Enum.map(paths, fn path -> {:i, path |> Path.expand(__DIR__) |> String.to_charlist()} end)
  end

  defp deps do
    [
      {:credo, "~> 1.7", [only: [:dev, :test], runtime: false]},
      {:dialyxir, "~> 1.4", [only: :dev, runtime: false]},
      {:ex_doc, "~> 0.40.5", [only: :dev, runtime: false]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: [],
      links: %{"Source" => "https://github.com/nshkrdotcom/med_ex"},
      files: [
        ".credo.exs",
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "assets",
        "components/core/med_capture/lib",
        "components/core/med_core/lib",
        "config",
        "guides/architecture_and_roadmap.md",
        "guides/durability_and_guarantees.md",
        "guides/history/med_rtc_changelog.md",
        "guides/host_integration.md",
        "guides/product_horizon.md",
        "guides/source_development.md",
        "guides/stability_and_compatibility.md",
        "guides/stream_recording.md",
        "mix.exs",
        "priv"
      ]
    ]
  end

  defp docs do
    Keyword.put(
      [
        groups_for_extras: [
          {"Overview", ["README.md", "guides/architecture_and_roadmap.md"]},
          {"Integration Guides",
           [
             "guides/stream_recording.md",
             "guides/durability_and_guarantees.md",
             "guides/stability_and_compatibility.md",
             "guides/host_integration.md",
             "guides/source_development.md"
           ]},
          {"Horizon", ["guides/product_horizon.md"]},
          {"Release", ["CHANGELOG.md", "guides/history/med_rtc_changelog.md", "LICENSE"]}
        ],
        assets: %{"assets" => "assets"},
        source_ref: "med_ex-v0.3.0",
        source_url: "https://github.com/nshkrdotcom/med_ex",
        logo: "assets/med_ex.svg",
        main: "readme",
        extras: [
          {"CHANGELOG.md", [title: "Changelog"]},
          {"LICENSE", [title: "License"]},
          {"README.md", [title: "Overview"]},
          {"guides/architecture_and_roadmap.md", [title: "Architecture and Composition"]},
          {"guides/durability_and_guarantees.md", [title: "Durability and Ordering Guarantees"]},
          {"guides/history/med_rtc_changelog.md", [title: "Historical MedRTC Changelog"]},
          {"guides/host_integration.md", [title: "Host Integration and Browser Compatibility"]},
          {"guides/product_horizon.md", [title: "Medical-Device Product Horizon"]},
          {"guides/source_development.md", [title: "Consumption, Extensions, and Verification"]},
          {"guides/stability_and_compatibility.md",
           [title: "Public Surface and 0.x Compatibility"]},
          {"guides/stream_recording.md", [title: "Streams, Storage, Clock, and Control"]}
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
end
