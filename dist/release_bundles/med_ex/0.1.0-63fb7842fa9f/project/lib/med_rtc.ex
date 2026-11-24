defmodule MedRTC do
  @moduledoc """
  OTP effect shell and WebRTC/Opus/SCTP runtime boundary for MedEx.

  Orchestrates live session coordination (`MedRTC.SessionServer`) and WebRTC
  peer negotiation (`MedRTC.PeerLoopback`) while delegating pure clinical signal
  invariants to `MedCore.Session`.
  """
end
