defmodule MedCapture.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_capture,
      version: File.read!(Path.join(__DIR__, "../../VERSION")) |> String.trim(),
      elixir: "~> 1.20",
      test_ignore_filters: ~w(test/test_helper.exs test/support/fixture_helper.exs),
      deps: [{:med_core, path: "../med_core"}]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
