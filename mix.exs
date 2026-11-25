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
        {:med_ex, "~> 0.2.0"},
        {:ex_webrtc, "~> 0.18.0"},
        {:ex_rtp, "~> 0.4"},
        {:ex_doc, "~> 0.40.5", only: :dev, runtime: false}
      ],
      description: "Optional WebRTC and RTP provider for MedEx",
      docs: [main: "readme", extras: ["README.md"]],
      package: [
        files: ~w(mix.exs VERSION LICENSE README.md lib),
        licenses: ["MIT"],
        links: %{"Source" => @source}
      ]
    ]
  end
end
