defmodule MedPulse.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/med_ex"

  def project do
    [
      app: :med_pulse,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs(),
      package: package(),
      name: "MedPulse",
      description:
        "First MedEx vertical-slice clinical application combining Use Case #1 (Remote Digital Stethoscope) and Use Case #4 (Remote Patient Monitoring: ECG/SpO2).",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:med_core, path: "../../core/med_core"},
      {:med_rtc, path: "../../core/med_rtc"},
      {:med_adapters, path: "../../core/med_adapters"},
      {:med_web, path: "../../core/med_web"},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.9", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.5", only: :dev, runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_add_deps: :apps_direct,
      flags: [:error_handling, :underspecs, :unknown]
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/med_pulse.svg",
      assets: %{"assets" => "assets"},
      source_ref: "main",
      source_url: @source_url,
      extras: [
        {"README.md", title: "Overview", filename: "readme"},
        {"CHANGELOG.md", title: "Changelog", filename: "changelog"},
        {"LICENSE", title: "License", filename: "license"}
      ]
    ]
  end

  defp package do
    [
      name: "med_pulse",
      licenses: ["MIT"],
      maintainers: ["nshkrdotcom"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/med_pulse/CHANGELOG.md"
      },
      files: ~w(lib assets mix.exs .formatter.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
