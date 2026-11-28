defmodule MedExOpus.MixProject do
  use Mix.Project

  @version File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()
  @source "https://github.com/nshkrdotcom/med_ex"

  def project do
    [
      app: :med_ex_opus,
      version: @version,
      elixir: "~> 1.20",
      compilers: [:elixir_make | Mix.compilers()],
      aliases: [
        quality: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "cmd env MIX_ENV=test mix test --warnings-as-errors --include startup_deadline",
          "credo --strict",
          "dialyzer",
          "docs --warnings-as-errors"
        ]
      ],
      deps: [
        {:elixir_make, "~> 0.10.1", runtime: false},
        {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4.9", only: :dev, runtime: false},
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
        files:
          ~w(.formatter.exs mix.exs Makefile VERSION LICENSE README.md CHANGELOG.md assets c_src lib),
        licenses: ["MIT"],
        links: %{"Source" => @source}
      ]
    ]
  end
end
