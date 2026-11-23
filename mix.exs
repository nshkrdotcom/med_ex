defmodule MedEx.Workspace.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/med_ex"

  def project do
    [
      app: :med_ex_workspace,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      blitz_workspace: blitz_workspace(),
      dialyzer: dialyzer(),
      docs: docs(),
      name: "MedEx Workspace",
      description:
        "Tooling root for the MedEx clinical WebRTC/Opus poncho framework and reference apps",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        ci: :test,
        "ci.full": :test,
        "monorepo.test": :test,
        "mr.test": :test,
        credo: :test
      ]
    ]
  end

  defp deps do
    [
      {:blitz, "~> 0.4.1", runtime: false},
      {:weld, "~> 0.13.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.9", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.5", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    monorepo_aliases = [
      "monorepo.deps.get": ["blitz.workspace deps_get"],
      "monorepo.format": ["blitz.workspace format"],
      "monorepo.compile": ["blitz.workspace compile"],
      "monorepo.test": ["blitz.workspace test"],
      "monorepo.credo": ["blitz.workspace credo"],
      "monorepo.dialyzer": ["blitz.workspace dialyzer"],
      "monorepo.docs": ["blitz.workspace docs"]
    ]

    mr_aliases = [
      "mr.deps.get": ["monorepo.deps.get"],
      "mr.format": ["monorepo.format"],
      "mr.compile": ["monorepo.compile"],
      "mr.test": ["monorepo.test"],
      "mr.credo": ["monorepo.credo"],
      "mr.dialyzer": ["monorepo.dialyzer"],
      "mr.docs": ["monorepo.docs"]
    ]

    [
      ci: [
        "format --check-formatted",
        "monorepo.format -- --check-formatted",
        "monorepo.compile",
        "monorepo.test",
        "monorepo.credo -- --strict"
      ],
      "ci.full": [
        "monorepo.deps.get",
        "format --check-formatted",
        "monorepo.format -- --check-formatted",
        "monorepo.compile",
        "monorepo.test",
        "monorepo.credo -- --strict",
        "monorepo.dialyzer",
        "weld.inspect",
        "weld.verify"
      ],
      quality: ["monorepo.credo -- --strict", "monorepo.dialyzer"]
    ] ++ monorepo_aliases ++ mr_aliases
  end

  defp blitz_workspace do
    [
      root: __DIR__,
      projects: ["core/*", "apps/*"],
      isolation: [
        deps_path: true,
        build_path: true,
        lockfile: true,
        hex_home: "_build/hex",
        unset_env: ["HEX_API_KEY"]
      ],
      parallelism: [
        multiplier: :auto,
        base: [
          deps_get: 4,
          format: 4,
          compile: 4,
          test: 4,
          credo: 4,
          dialyzer: 4,
          docs: 4
        ],
        overrides: []
      ],
      tasks: [
        deps_get: [args: ["deps.get"], preflight?: false],
        format: [args: ["format"]],
        compile: [args: ["compile", "--warnings-as-errors"]],
        test: [args: ["test"], mix_env: "test", color: true],
        credo: [args: ["credo"]],
        dialyzer: [args: ["dialyzer", "--force-check"]],
        docs: [args: ["docs"]]
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_deps: :apps_direct,
      plt_add_apps: [:mix, :blitz, :weld]
    ]
  end

  defp docs do
    [
      main: "readme",
      before_closing_body_tag: &docs_diagrams/1,
      logo: "assets/med_ex.svg",
      assets: %{"assets" => "assets"},
      source_ref: "main",
      extras: [
        {"README.md", filename: "readme", title: "Overview"},
        {"CHANGELOG.md", filename: "changelog", title: "Changelog"},
        {"LICENSE", filename: "license", title: "License"},
        "guides/host_integration.md",
        "guides/architecture_and_roadmap.md",
        "guides/source_development.md",
        {"core/med_rtc/README.md", filename: "med_rtc", title: "MedRTC"},
        {"core/med_web/README.md", filename: "med_web", title: "MedWeb"}
      ],
      groups_for_extras: [
        Overview: ["README.md"],
        Guides:
          ~w(guides/host_integration.md guides/architecture_and_roadmap.md guides/source_development.md),
        Projects: [
          "core/med_rtc/README.md",
          "core/med_web/README.md"
        ],
        Release: ~w(CHANGELOG.md LICENSE)
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
