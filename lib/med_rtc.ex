defmodule MedRTC do
  @moduledoc """
  OTP effect shell and WebRTC/Opus/SCTP runtime boundary for MedEx.

  Orchestrates per-session supervision trees, media pipelines, and effect
  interpretation while delegating clinical signal invariants to `MedCore`.
  """

  @spec core_version() :: String.t()
  def core_version, do: MedCore.version()
end
