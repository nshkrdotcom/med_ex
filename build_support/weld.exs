[
  workspace: [root: "..", project_globs: ["core/*", "extensions/*", "tools/*"]],
  artifacts: [
    med_ex: [
      mode: :source_project,
      roots: ["."],
      source_project: [
        files:
          ~w(mix.exs mix.lock VERSION LICENSE README.md CHANGELOG.md .formatter.exs assets guides
                  priv test core/med_core/lib core/med_core/test core/med_capture/lib core/med_capture/test
                  build_support),
        structural_inputs: ~w(mix.exs VERSION core/med_core/mix.exs core/med_capture/mix.exs)
      ],
      package: [
        name: "med_ex",
        otp_app: :med_ex,
        version: File.read!(Path.join(__DIR__, "../VERSION")) |> String.trim(),
        elixir: "~> 1.20",
        description: "Source-preserving waveform and measurement acquisition",
        licenses: ["MIT"],
        maintainers: ["nshkrdotcom"],
        links: %{"Source" => "https://github.com/nshkrdotcom/med_ex"}
      ],
      verify: [hex_build: true, hex_publish: false]
    ]
  ]
]
