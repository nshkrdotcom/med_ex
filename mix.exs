defmodule MedEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_ex,
      version: "0.1.0",
      build_path: "_build",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: [],
      deps: deps(),
      description: "Live clinical audio capture and independent WebRTC Opus preview",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def elixirc_paths(:test) do
    if File.dir?("test/support") do
      ["lib", "test/support"]
    else
      ["lib"]
    end
  end

  def elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ex_rtp, "~> 0.4"},
      {:ex_webrtc, "~> 0.18.0"},
      {:membrane_opus_plugin, "~> 0.21.0"},
      {:credo, "~> 1.7.19", [only: [:dev, :test], runtime: false]},
      {:dialyxir, "~> 1.4.9", [only: [:dev, :test], runtime: false]},
      {:ex_doc, "~> 0.40.5", [only: :dev, runtime: false]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["nshkrdotcom"],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/med_ex"},
      files: [
        ".credo.exs",
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "assets/med_ex.svg",
        "config",
        "guides",
        "lib",
        "mix.exs",
        "priv",
        "projection.lock.json"
      ]
    ]
  end

  defp docs do
    Keyword.put(
      [
        groups_for_extras: [
          {"Overview", ["README.md"]},
          {"Guides",
           [
             "guides/host_integration.md",
             "guides/architecture_and_roadmap.md",
             "guides/source_development.md"
           ]},
          {"Release", ["CHANGELOG.md", "LICENSE"]}
        ],
        assets: %{"assets" => "assets"},
        source_ref: "med_ex-v0.1.0",
        source_url: "https://github.com/nshkrdotcom/med_ex",
        homepage_url: "https://github.com/nshkrdotcom/med_ex",
        logo: "assets/med_ex.svg",
        main: "readme",
        extras: [
          {"CHANGELOG.md", [title: "Changelog"]},
          {"LICENSE", [title: "License"]},
          {"README.md", [title: "Overview"]},
          "guides/architecture_and_roadmap.md",
          "guides/host_integration.md",
          "guides/source_development.md"
        ]
      ],
      :before_closing_body_tag,
      fn
        :html ->
          "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@11.12.2/dist/mermaid.min.js\"></script>\n<script>\ndocument.addEventListener(\"DOMContentLoaded\", () => {\n  const diagrams = document.querySelectorAll(\"pre code.mermaid\");\n  if (!diagrams.length || !window.mermaid) return;\n  mermaid.initialize({startOnLoad: false, securityLevel: \"strict\"});\n  for (const code of diagrams) {\n    const diagram = document.createElement(\"div\");\n    diagram.className = \"mermaid\";\n    diagram.textContent = code.textContent;\n    code.parentElement.replaceWith(diagram);\n  }\n  mermaid.run();\n});\n</script>\n"

        _ ->
          ""
      end
    )
  end
end
