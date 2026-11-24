Code.require_file("build_support/sources.exs", __DIR__)

defmodule MedExRTC.MixProject do
  use Mix.Project
  @version File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()
  def project do
    defaults = [
      {:med_ex, "~> 0.2.0",
       github: "nshkrdotcom/med_ex", ref: "83defa6d16e5062b3b027cb0e1dbec98bac38705"},
      {:ex_webrtc, "~> 0.18.0"},
      {:ex_rtp, "~> 0.4"}
    ]

    root = Path.expand("../..", __DIR__)

    in_checkout =
      Path.basename(Path.dirname(__DIR__)) == "extensions" and
        File.regular?(Path.join(root, "core/med_core/mix.exs"))

    base = if in_checkout, do: root, else: __DIR__
    {deps, paths} = MedExRTC.BuildSources.resolve(defaults, __DIR__, base)

    [
      app: :med_ex_rtc,
      version: @version,
      elixir: "~> 1.20",
      deps: deps,
      description: "Optional MedEx media provider",
      package: [
        files: ~w(VERSION mix.exs LICENSE lib build_support),
        licenses: ["MIT"],
        links: %{"Source" => "https://github.com/nshkrdotcom/med_ex"}
      ]
    ] ++ paths
  end
end
