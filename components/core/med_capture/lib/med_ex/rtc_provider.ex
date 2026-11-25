defmodule MedEx.RTCProvider do
  @moduledoc """
  Optional RTC port. The legacy facade remains base-owned and preserves
  %MedEx.Preview{pid, track_id}, with pid the real ExWebRTC peer. A provider
  neither starts nor owns authoritative recording. Legacy provider is fixed
  for the VM lifetime; a new provider-aware API may use richer handles.
  """
  @type peer :: %{
          required(:pid) => pid(),
          required(:track_id) => term(),
          optional(atom()) => term()
        }
  @callback answer(binary(), keyword()) :: {:ok, peer(), binary()} | {:error, term()}
  @callback send_opus(peer(), binary(), non_neg_integer(), non_neg_integer()) :: :ok
  @callback close(peer()) :: :ok
end
