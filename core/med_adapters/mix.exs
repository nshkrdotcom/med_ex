defmodule MedAdapters.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/med_ex"

  def project do
    [
      app: :med_adapters,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs(),
      package: package(),
      name: "MedAdapters",
      description:
        "Behaviour-driven clinical OSS adapters for MedEx: Ortex/ONNX, NeuroKit2/WFDB ports, FHIR, Orthanc DICOMweb, and external SFU/voice-AI bridges.",
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
      {:med_core, path: "../med_core"},
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
      logo: "assets/med_adapters.svg",
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
      name: "med_adapters",
      licenses: ["MIT"],
      maintainers: ["nshkrdotcom"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/core/med_adapters/CHANGELOG.md"
      },
      files: ~w(lib assets mix.exs .formatter.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
