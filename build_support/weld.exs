[
  workspace: [
    root: "..",
    project_globs: ["core/*", "apps/*"]
  ],
  classify: [
    tooling: ["."],
    proofs: ["apps/pulse_scope"]
  ],
  publication: [
    internal_only: ["."]
  ],
  artifacts: [
    med_ex: [
      mode: :monolith,
      roots: [
        "core/med_core",
        "core/med_rtc",
        "core/med_adapters",
        "core/med_web"
      ],
      package: [
        name: "med_ex",
        otp_app: :med_ex,
        version: "0.1.0",
        elixir: "~> 1.18",
        description:
          "Clinical-grade Elixir/Phoenix/LiveView/WebRTC/Opus framework for connected medical devices",
        licenses: ["MIT"],
        maintainers: ["nshkrdotcom"],
        links: %{"GitHub" => "https://github.com/nshkrdotcom/med_ex"},
        docs: [
          main: "readme",
          logo: "assets/med_ex.svg",
          homepage_url: "https://github.com/nshkrdotcom/med_ex",
          source_url: "https://github.com/nshkrdotcom/med_ex",
          source_ref: "v0.1.0",
          assets: %{"assets" => "assets"},
          extra_titles: %{
            "README.md" => "Overview",
            "CHANGELOG.md" => "Changelog",
            "LICENSE" => "License"
          },
          groups_for_extras: [
            {"Overview", ["README.md"]},
            {"Release", ["CHANGELOG.md", "LICENSE"]}
          ]
        ]
      ],
      output: [
        docs: [
          "README.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        assets: ["assets/med_ex.svg"]
      ],
      verify: [
        hex_build: true,
        hex_publish: false
      ]
    ]
  ]
]
