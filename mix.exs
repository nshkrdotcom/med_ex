defmodule MedEx.MixProject do
  use Mix.Project
  @version File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()
  @sources ~w(core/med_core/lib core/med_capture/lib)
  def project do
    [
      app: :med_ex,
      version: @version,
      elixir: "~> 1.20",
      deps: [{:ex_doc, "~> 0.40.5", only: :dev, runtime: false}],
      docs: [
        main: "readme",
        extras: ["README.md", "guides/host_integration.md", "guides/source_development.md"]
      ],
      description: "Source-preserving waveform and measurement acquisition",
      elixirc_paths: @sources,
      test_paths: ~w(test core/med_core/test core/med_capture/test),
      package: [
        licenses: ["MIT"],
        links: %{"Source" => "https://github.com/nshkrdotcom/med_ex"},
        files: @sources ++ ~w(mix.exs VERSION priv guides assets LICENSE README.md CHANGELOG.md)
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
