defmodule MedExRTC.MixProject do
  use Mix.Project

  @version File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()
  @source "https://github.com/nshkrdotcom/med_ex"

  def project do
    [
      app: :med_ex_rtc,
      version: @version,
      elixir: "~> 1.20",
      deps: [
        {:ex_webrtc, "~> 0.18.0"},
        {:ex_rtp, "~> 0.4"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: :dev, runtime: false},
        {:ex_doc, "~> 0.40.5", only: :dev, runtime: false}
      ],
      description: "Optional WebRTC and RTP provider for MedEx",
      docs: [
        main: "readme",
        logo: "assets/med_ex_rtc.svg",
        assets: %{"assets" => "assets"},
        extras: [
          "README.md": [title: "Overview"],
          "CHANGELOG.md": [title: "Changelog"],
          LICENSE: [title: "License"]
        ],
        groups_for_extras: [Release: ["CHANGELOG.md", "LICENSE"]]
      ],
      package: [
        files: ~w(.formatter.exs mix.exs VERSION LICENSE README.md CHANGELOG.md assets lib),
        licenses: ["MIT"],
        links: %{"Source" => @source}
      ]
    ]
  end
end
