defmodule MedCore do
  @moduledoc """
  Pure functional clinical domain core for the MedEx framework.

  Defines clinical stream specifications, encounter state contracts,
  product profile behaviours, and deterministic state-machine seams.
  """

  @spec version() :: String.t()
  def version, do: "0.1.0"
end
