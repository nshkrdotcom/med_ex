defmodule MedCore do
  @moduledoc """
  Pure functional clinical signal and live-session domain core for MedEx.

  Defines stream contracts, live session state, preview vs. recording integrity
  types, product profile behaviours, and deterministic state-machine seams.
  """

  @spec version() :: String.t()
  def version, do: "0.1.0"
end
