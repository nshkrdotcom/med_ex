version = __DIR__ |> Path.join("../VERSION") |> File.read!() |> String.trim()

[
  workspace: [
    root: "..",
    project_globs: ["core/*", "apps/*"]
  ],
  classify: [
    tooling: ["."]
  ],
  publication: [
    internal_only: ["."]
  ],
  artifacts: [
    med_ex: [
      mode: :monolith,
      roots: [
        "core/med_rtc",
        "core/med_web"
      ],
      package: [
        name: "med_ex",
        otp_app: :med_ex,
        version: version,
        elixir: "~> 1.20",
        description: "Live clinical audio capture and independent WebRTC Opus preview",
        licenses: ["MIT"],
        maintainers: ["nshkrdotcom"],
        links: %{"GitHub" => "https://github.com/nshkrdotcom/med_ex"},
        docs: [
          mermaid: true,
          main: "readme",
          logo: "assets/med_ex.svg",
          homepage_url: "https://github.com/nshkrdotcom/med_ex",
          source_url: "https://github.com/nshkrdotcom/med_ex",
          source_ref: "med_ex-v#{version}",
          assets: %{"assets" => "assets"},
          extra_titles: %{
            "README.md" => "Overview",
            "CHANGELOG.md" => "Changelog",
            "LICENSE" => "License"
          },
          groups_for_extras: [
            {"Overview", ["README.md"]},
            {"Guides",
             [
               "guides/host_integration.md",
               "guides/architecture_and_roadmap.md",
               "guides/source_development.md"
             ]},
            {"Release", ["CHANGELOG.md", "LICENSE"]}
          ]
        ]
      ],
      output: [
        docs: [
          "README.md",
          "guides/host_integration.md",
          "guides/architecture_and_roadmap.md",
          "guides/source_development.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        assets: ["assets/med_ex.svg"]
      ],
      verify: [
        hex_build: true,
        hex_publish: true
      ]
    ]
  ]
]
