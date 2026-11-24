Code.require_file("build_support/sources.exs", __DIR__)

defmodule MedExOpus.MixProject do
  use Mix.Project
  @version File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()
  def project do
    defaults = [
      {:med_ex, "~> 0.2.0",
       github: "nshkrdotcom/med_ex", ref: "c031a38a9e28fe6bccf1358d8f41fa419aa708d2"},
      {:membrane_core, "~> 1.0"},
      {:membrane_raw_audio_format, "~> 0.12.0"},
      {:membrane_opus_format, "~> 0.3.0"},
      {:membrane_opus_plugin, "~> 0.21.0"}
    ]

    root = Path.expand("../..", __DIR__)

    in_checkout =
      Path.basename(Path.dirname(__DIR__)) == "extensions" and
        File.regular?(Path.join(root, "core/med_core/mix.exs"))

    base = if in_checkout, do: root, else: __DIR__
    {deps, paths} = MedExOpus.BuildSources.resolve(defaults, __DIR__, base)

    [
      app: :med_ex_opus,
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
