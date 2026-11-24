defmodule MedCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_core,
      version: File.read!(Path.join(__DIR__, "../../VERSION")) |> String.trim(),
      elixir: "~> 1.20",
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
