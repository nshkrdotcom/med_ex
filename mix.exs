defmodule MedEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_ex,
      version: "0.1.0",
      build_path: "_build",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: [],
      deps: deps(),
      description:
        "Browser-capable clinical WebRTC/Opus/SCTP live-session and signal-integrity SDK for connected medical devices",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  def elixirc_paths(:test) do
    if File.dir?("test/support") do
      ["lib", "test/support"]
    else
      ["lib"]
    end
  end

  def elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ex_rtp, "~> 0.4"},
      {:ex_webrtc, "~> 0.18.0"},
      {:credo, "~> 1.7.19", [only: [:dev, :test], runtime: false]},
      {:dialyxir, "~> 1.4.9", [only: [:dev, :test], runtime: false]},
      {:ex_doc, "~> 0.40.5", [only: :dev, runtime: false]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["nshkrdotcom"],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/med_ex"},
      files: [
        ".credo.exs",
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "assets/med_ex.svg",
        "config",
        "lib",
        "mix.exs",
        "priv",
        "projection.lock.json"
      ]
    ]
  end

  defp docs do
    [
      groups_for_extras: [
        {"Overview", ["README.md"]},
        {"Release", ["CHANGELOG.md", "LICENSE"]}
      ],
      assets: %{"assets" => "assets"},
      source_ref: "v0.1.0",
      source_url: "https://github.com/nshkrdotcom/med_ex",
      homepage_url: "https://github.com/nshkrdotcom/med_ex",
      logo: "assets/med_ex.svg",
      main: "readme",
      extras: [
        {"CHANGELOG.md", [title: "Changelog"]},
        {"LICENSE", [title: "License"]},
        {"README.md", [title: "Overview"]}
      ]
    ]
  end
end
