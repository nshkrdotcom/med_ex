defmodule MedRTC do
  @moduledoc """
  OTP effect shell and WebRTC/Opus/SCTP runtime boundary for MedEx.

  Orchestrates per-encounter supervision trees, media pipelines, and effect
  interpretation while delegating clinical invariants to `MedCore`.
  """

  @spec core_version() :: String.t()
  def core_version, do: MedCore.version()
end
