defmodule MedWeb do
  @moduledoc """
  Reusable Phoenix signaling, clinical LiveComponents, and WebAudio workbench
  primitives for MedEx applications.
  """

  @spec runtime_core_version() :: String.t()
  def runtime_core_version, do: MedRTC.core_version()
end
