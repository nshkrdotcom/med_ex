defmodule MedRTC.Preview do
  @moduledoc """
  One replaceable, send-only WebRTC peer for an Opus preview. The caller owns
  the peer and receives its ExWebRTC state changes. Capture has its own lifetime.
  """

  alias ExRTP.Packet
  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}

  @enforce_keys [:pid, :track_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{pid: pid(), track_id: MediaStreamTrack.id()}

  @doc "Answers a receive-only audio offer containing the browser's ICE candidates."
  @spec answer(String.t()) :: {:ok, t(), String.t()} | {:error, term()}
  def answer(offer_sdp) when is_binary(offer_sdp) do
    with {:ok, pid} <-
           PeerConnection.start_link(ice_servers: [], audio_codecs: [:opus], video_codecs: []) do
      track = MediaStreamTrack.new(:audio)
      peer = %__MODULE__{pid: pid, track_id: track.id}

      case negotiate(peer, track, offer_sdp) do
        {:ok, sdp} ->
          {:ok, peer, sdp}

        error ->
          close(peer)
          error
      end
    end
  end

  defp negotiate(%__MODULE__{pid: pid}, track, offer_sdp) do
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

  @doc "Sends one 20 ms Opus frame. Frame indices are relative to the acquisition."
  @spec send_opus(t(), binary(), non_neg_integer()) :: :ok
  def send_opus(%__MODULE__{pid: pid, track_id: id}, payload, index) do
    packet =
      Packet.new(payload,
        sequence_number: rem(index, 65_536),
        timestamp: rem(index * 960, 4_294_967_296)
      )

    PeerConnection.send_rtp(pid, id, packet)
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
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
