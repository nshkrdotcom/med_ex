defmodule MedEx.Maintainer.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_ex_maintainer,
      version: "0.0.0",
      elixir: "~> 1.20",
      deps: [{:weld, "~> 0.17.0", runtime: false}]
    ]
  end
end
