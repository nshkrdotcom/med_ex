defmodule MedEx.RTC.Provider do
  @behaviour MedEx.RTCProvider
  alias MedEx.Preview

  @moduledoc """
  One replaceable, send-only WebRTC peer for an Opus preview. The caller owns
  the peer and receives its ExWebRTC state changes. Capture has its own lifetime.
  """

  alias ExRTP.Packet
  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}

  @type t :: %Preview{pid: pid(), track_id: term()}

  @doc """
  Answers a receive-only browser audio offer containing the browser's ICE candidates.

  The calling process owns the resulting `ExWebRTC.PeerConnection` and receives
  `{:ex_webrtc, peer.pid, {:connection_state_change, state}}` messages (such as
  `:connected`, `:failed`, and `:closed`). Call `close/1` on teardown.

  ## Options

    * `:ice_servers` — list of ICE server maps passed to `ExWebRTC.PeerConnection`
      (defaults to `[]` for direct local candidates).
    * `:ice_transport_policy` — `:all` (default) or `:relay`. For relay-only
      preview, supply TURN credentials and select relay on the browser too.
  """
  @spec answer(String.t(), keyword()) :: {:ok, t(), String.t()} | {:error, term()}
  def answer(offer_sdp, opts \\ []) when is_binary(offer_sdp) do
    with {:ok, pid} <-
           PeerConnection.start_link(
             ice_servers: Keyword.get(opts, :ice_servers, []),
             ice_transport_policy: Keyword.get(opts, :ice_transport_policy, :all),
             audio_codecs: [:opus],
             video_codecs: []
           ) do
      track = MediaStreamTrack.new(:audio)
      peer = %Preview{pid: pid, track_id: track.id}

      case negotiate(peer, track, offer_sdp) do
        {:ok, sdp} ->
          {:ok, peer, sdp}

        error ->
          close(peer)
          error
      end
    end
  end

  defp negotiate(%Preview{pid: pid}, track, offer_sdp) do
    offer = %SessionDescription{type: :offer, sdp: offer_sdp}

    with :ok <- PeerConnection.set_remote_description(pid, offer),
         {:ok, _sender} <- PeerConnection.add_track(pid, track),
         {:ok, answer} <- PeerConnection.create_answer(pid),
         :ok <- PeerConnection.set_local_description(pid, answer),
         :ok <- await_gathering(pid) do
      %SessionDescription{sdp: sdp} = PeerConnection.get_local_description(pid)
      {:ok, sdp}
    end
  end

  @doc """
  Sends one Opus RTP packet with separate per-peer `sequence` (wrapped mod
  `65_536`) and 48 kHz media clock `sample_index` (wrapped mod `2^32`).
  """
  @spec send_opus(t(), binary(), non_neg_integer(), non_neg_integer()) :: :ok
  def send_opus(%Preview{pid: pid, track_id: id}, payload, sequence, sample_index) do
    packet =
      Packet.new(payload,
        sequence_number: rem(sequence, 65_536),
        timestamp: rem(sample_index, 4_294_967_296)
      )

    PeerConnection.send_rtp(pid, id, packet)
  end

  @doc "Stops the underlying WebRTC peer connection if it is still alive."
  @spec close(t()) :: :ok
  def close(%Preview{pid: pid}) do
    if Process.alive?(pid), do: PeerConnection.stop(pid)
    :ok
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, {:normal, _call} -> :ok
  end

  defp await_gathering(pid) do
    if PeerConnection.get_ice_gathering_state(pid) == :complete do
      :ok
    else
      receive do
        {:ex_webrtc, ^pid, {:ice_gathering_state_change, :complete}} -> :ok
      after
        5_000 -> {:error, :ice_gathering_timeout}
      end
    end
  end
end
