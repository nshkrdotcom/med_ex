defmodule MedExOpus.MixProject do
  use Mix.Project

  @version File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()
  @source "https://github.com/nshkrdotcom/med_ex"

  def project do
    [
      app: :med_ex_opus,
      version: @version,
      elixir: "~> 1.20",
      deps: [
        {:med_ex, "~> 0.2.0"},
        {:membrane_core, "~> 1.0"},
        {:membrane_raw_audio_format, "~> 0.12.0"},
        {:membrane_opus_format, "~> 0.3.0"},
        {:membrane_opus_plugin, "~> 0.21.0"},
        {:ex_doc, "~> 0.40.5", only: :dev, runtime: false}
      ],
      description: "Optional Opus encoding provider for MedEx",
      docs: [
        main: "readme",
        logo: "assets/med_ex_opus.svg",
        assets: %{"assets" => "assets"},
        extras: [
          "README.md": [title: "Overview"],
          "CHANGELOG.md": [title: "Changelog"],
          LICENSE: [title: "License"]
        ],
        groups_for_extras: [Release: ["CHANGELOG.md", "LICENSE"]]
      ],
      package: [
        files: ~w(mix.exs VERSION LICENSE README.md CHANGELOG.md assets lib),
        licenses: ["MIT"],
        links: %{"Source" => @source}
      ]
    ]
  end
end
