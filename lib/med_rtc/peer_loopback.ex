defmodule MedRTC.PeerLoopback do
  @moduledoc """
  Minimal real `ExWebRTC.PeerConnection` SDP/ICE loopback harness used to
  exercise live WebRTC negotiation, peer disconnect, and replacement connection
  establishment against `MedRTC.SessionServer`.
  """

  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription

  @type negotiated_pair :: %{
          required(:connection_id) => String.t(),
          required(:offerer) => pid(),
          required(:answerer) => pid(),
          required(:offer_sdp) => String.t(),
          required(:answer_sdp) => String.t()
        }

  @doc """
  Starts two real `ExWebRTC.PeerConnection` instances with an `:audio`
  transceiver, exchanges SDP offer/answer and ICE candidates, and waits until
  both peers reach `:connected`.
  """
  @spec connect_pair(String.t(), pos_integer()) :: {:ok, negotiated_pair()} | {:error, term()}
  def connect_pair(connection_id, timeout_ms \\ 5_000) when is_binary(connection_id) do
    with {:ok, offerer} <- PeerConnection.start_link(ice_servers: []),
         {:ok, answerer} <- PeerConnection.start_link(ice_servers: []),
         {:ok, _transceiver} <- PeerConnection.add_transceiver(offerer, :audio),
         {:ok, %SessionDescription{sdp: offer_sdp} = offer} <-
           PeerConnection.create_offer(offerer),
         :ok <- PeerConnection.set_local_description(offerer, offer),
         :ok <- PeerConnection.set_remote_description(answerer, offer),
         {:ok, %SessionDescription{sdp: answer_sdp} = answer} <-
           PeerConnection.create_answer(answerer),
         :ok <- PeerConnection.set_local_description(answerer, answer),
         :ok <- PeerConnection.set_remote_description(offerer, answer),
         :ok <- relay_until_connected(offerer, answerer, false, false, timeout_ms) do
      {:ok,
       %{
         connection_id: connection_id,
         offerer: offerer,
         answerer: answerer,
         offer_sdp: offer_sdp,
         answer_sdp: answer_sdp
       }}
    end
  end

  @doc """
  Closes both `ExWebRTC.PeerConnection` processes in a negotiated pair.
  """
  @spec close_pair(negotiated_pair()) :: :ok
  def close_pair(%{offerer: offerer, answerer: answerer}) do
    safe_close(offerer)
    safe_close(answerer)
    :ok
  end

  defp safe_close(pid) when is_pid(pid) do
    if Process.alive?(pid), do: PeerConnection.close(pid)
  catch
    :exit, _ -> :ok
  end

  defp relay_until_connected(_offerer, _answerer, true, true, _timeout_ms), do: :ok

  defp relay_until_connected(offerer, answerer, offerer_connected?, answerer_connected?, timeout) do
    receive do
      {:ex_webrtc, ^offerer, {:ice_candidate, cand}} ->
        :ok = PeerConnection.add_ice_candidate(answerer, cand)
        relay_until_connected(offerer, answerer, offerer_connected?, answerer_connected?, timeout)

      {:ex_webrtc, ^answerer, {:ice_candidate, cand}} ->
        :ok = PeerConnection.add_ice_candidate(offerer, cand)
        relay_until_connected(offerer, answerer, offerer_connected?, answerer_connected?, timeout)

      {:ex_webrtc, ^offerer, {:connection_state_change, :connected}} ->
        relay_until_connected(offerer, answerer, true, answerer_connected?, timeout)

      {:ex_webrtc, ^answerer, {:connection_state_change, :connected}} ->
        relay_until_connected(offerer, answerer, offerer_connected?, true, timeout)

      {:ex_webrtc, _pid, _other} ->
        relay_until_connected(offerer, answerer, offerer_connected?, answerer_connected?, timeout)
    after
      timeout ->
        {:error, {:webrtc_connect_timeout, offerer_connected?, answerer_connected?}}
    end
  end
end
