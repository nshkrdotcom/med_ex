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
      deps: [
        {:med_ex, "~> 0.3.0"},
        {:elixir_make, "~> 0.9", runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: :dev, runtime: false},
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
