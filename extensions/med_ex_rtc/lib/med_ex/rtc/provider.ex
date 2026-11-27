defmodule MedEx.RTC.Provider do
  @moduledoc """
  Concrete owner-bound send-only Opus/WebRTC peer. The opaque handle exposes only
  `peer_ref/1` for matching `{:med_ex_rtc, peer_ref, state}` notifications. The
  owner supplies logical emitted sequence and elapsed 48 kHz media ticks; this
  boundary alone performs modulo conversion. A caller-local monotonic deadline
  is checked immediately before transport submission. Unknown sends retire the
  peer; already submitted packets cannot be recalled.
  """
  use GenServer, restart: :temporary
  alias ExRTP.Packet
  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}
  @enforce_keys [:pid, :ref, :owner]
  defstruct @enforce_keys
  @opaque t :: %__MODULE__{pid: pid(), ref: reference(), owner: pid()}
  @negotiation_ms 10_000
  @gathering_ms 5_000
  @operation_ms 1_000
  @max_sdp 65_536

  def answer(offer, opts) when is_binary(offer) and is_list(opts) do
    with :ok <- validate_options(opts),
         :ok <- offer(offer),
         owner = opts[:owner],
         ref = make_ref(),
         {:ok, pid} <-
           GenServer.start_link(
             __MODULE__,
             %{
               owner: owner,
               caller: self(),
               ref: ref,
               offer: offer,
               options: opts,
               deadline: now() + @negotiation_ms
             },
             timeout: @negotiation_ms + 1_000
           ) do
      handle = %__MODULE__{pid: pid, ref: ref, owner: owner}

      try do
        case GenServer.call(pid, {:answer, ref}, @operation_ms) do
          {:ok, sdp} ->
            {:ok, handle, sdp}

          _ ->
            retire(handle)
            {:error, :negotiation_failed}
        end
      catch
        :exit, _ ->
          retire(handle)
          {:error, :negotiation_failed}
      end
    end
  end

  def answer(_, _), do: {:error, :invalid_offer_or_options}
  def peer_ref(%__MODULE__{ref: ref}), do: ref

  def send_opus(%__MODULE__{owner: owner} = peer, packet, sequence, media_tick, deadline)
      when owner == self() do
    if valid_packet?(packet, sequence, media_tick) and is_integer(deadline) do
      remaining = deadline - now()

      if remaining > 0 do
        GenServer.call(
          peer.pid,
          {:send_opus, peer.ref, packet, sequence, media_tick, deadline},
          min(remaining, @operation_ms)
        )
      else
        {:error, {:not_committed, :expired}}
      end
    else
      {:error, {:not_committed, :invalid_packet}}
    end
  catch
    :exit, _ ->
      retire(peer)
      {:error, {:outcome_unknown, :rtc_call_failed}}
  end

  def send_opus(%__MODULE__{}, _, _, _, _), do: {:error, :not_owner}
  def send_opus(_, _, _, _, _), do: {:error, :invalid_peer}

  def close(%__MODULE__{owner: owner} = peer) when owner == self() do
    if Process.alive?(peer.pid),
      do: GenServer.call(peer.pid, {:close, peer.ref}, @operation_ms),
      else: :ok
  catch
    :exit, {:noproc, _} ->
      :ok

    :exit, {:normal, _} ->
      :ok

    :exit, _ ->
      retire(peer)
      {:error, {:outcome_unknown, :rtc_close_failed}}
  end

  def close(%__MODULE__{}), do: {:error, :not_owner}
  def close(_), do: {:error, :invalid_peer}

  @impl true
  def init(initial) do
    case initialize(initial) do
      {:stop, _} = failure ->
        # Failed startup must return the refusal without sending the caller an exit.
        Process.unlink(initial.caller)
        failure

      success ->
        success
    end
  end

  defp initialize(initial) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(initial.owner)
    caller_ref = Process.monitor(initial.caller)

    if now() >= initial.deadline or not Process.alive?(initial.owner) do
      {:stop, :negotiation_abandoned}
    else
      options = [
        ice_servers:
          Enum.map(Keyword.get(initial.options, :ice_servers, []), &ice_server_options/1),
        ice_transport_policy: Keyword.get(initial.options, :ice_transport_policy, :all),
        audio_codecs: [:opus],
        video_codecs: [],
        controlling_process: self()
      ]

      case PeerConnection.start_link(options, timeout: @operation_ms) do
        {:ok, pc} ->
          result = negotiate(pc, initial, owner_ref, caller_ref)

          case result do
            {:ok, track_id, answer} ->
              {:ok,
               %{
                 owner: initial.owner,
                 owner_ref: owner_ref,
                 caller: initial.caller,
                 caller_ref: caller_ref,
                 ref: initial.ref,
                 pc: pc,
                 track_id: track_id,
                 answer: answer,
                 state: :connecting,
                 expiry: nil
               }}

            {:error, reason} ->
              stop_pc(pc)
              {:stop, reason}
          end

        _ ->
          {:stop, :peer_start_failed}
      end
    end
  rescue
    _ -> {:stop, :negotiation_failed}
  end

  defp negotiate(pc, initial, owner_ref, caller_ref) do
    track = MediaStreamTrack.new(:audio)

    with :ok <-
           PeerConnection.set_remote_description(pc, %SessionDescription{
             type: :offer,
             sdp: initial.offer
           }),
         {:ok, sender} <- PeerConnection.add_track(pc, track),
         [transceiver] <- PeerConnection.get_transceivers(pc),
         true <- transceiver.sender.id == sender.id,
         :ok <- PeerConnection.set_transceiver_direction(pc, transceiver.id, :sendonly),
         {:ok, answer} <- PeerConnection.create_answer(pc),
         :ok <- PeerConnection.set_local_description(pc, answer),
         :ok <-
           await_gathering(
             pc,
             min(initial.deadline, now() + @gathering_ms),
             initial,
             owner_ref,
             caller_ref
           ),
         true <-
           now() < initial.deadline and Process.alive?(initial.owner) and
             Process.alive?(initial.caller),
         %SessionDescription{sdp: sdp} <- PeerConnection.get_local_description(pc),
         true <- String.contains?(sdp, "a=sendonly") and byte_size(sdp) <= @max_sdp do
      {:ok, track.id, sdp}
    else
      _ -> {:error, :negotiation_failed}
    end
  rescue
    _ -> {:error, :negotiation_failed}
  catch
    :exit, _ -> {:error, :negotiation_failed}
  end

  defp await_gathering(pc, deadline, initial, owner_ref, caller_ref) do
    cond do
      now() >= deadline ->
        {:error, :ice_gathering_timeout}

      PeerConnection.get_ice_gathering_state(pc) == :complete ->
        :ok

      true ->
        receive do
          {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}} ->
            :ok

          {:ex_webrtc, ^pc, {:connection_state_change, state}} when state in [:failed, :closed] ->
            {:error, :connection_failed}

          {:DOWN, ^owner_ref, :process, _, _} ->
            {:error, :owner_down}

          {:DOWN, ^caller_ref, :process, _, _} ->
            {:error, :caller_down}

          {:EXIT, ^pc, _} ->
            {:error, :peer_down}

          {:EXIT, caller, _} when caller == initial.caller ->
            {:error, :caller_down}
        after
          max(deadline - now(), 0) -> {:error, :ice_gathering_timeout}
        end
    end
  end

  @impl true
  def handle_call({:answer, ref}, {caller, _}, %{ref: ref, caller: caller} = s),
    do: {:reply, {:ok, s.answer}, s}

  def handle_call(_, {caller, _}, s) when caller != s.owner, do: {:reply, {:error, :not_owner}, s}
  def handle_call({:close, ref}, _, %{ref: ref} = s), do: {:stop, :normal, :ok, s}

  def handle_call({:send_opus, ref, payload, sequence, tick, deadline}, _, %{ref: ref} = s) do
    cond do
      not valid_packet?(payload, sequence, tick) or not is_integer(deadline) ->
        {:reply, {:error, {:not_committed, :invalid_packet}}, s}

      now() >= deadline ->
        {:stop, :normal, {:error, {:not_committed, :expired}}, s}

      s.state != :connected ->
        {:reply, {:error, {:not_committed, :not_connected}}, s}

      true ->
        case submit(s, payload, sequence, tick, deadline) do
          :ok -> {:reply, :ok, arm_expiry(s, deadline)}
          {:error, {:not_committed, _} = reason} -> {:reply, {:error, reason}, s}
          {:error, reason} -> {:stop, :normal, {:error, reason}, s}
        end
    end
  end

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_peer_operation}, s}

  defp submit(s, payload, sequence, tick, deadline) do
    # ExWebRTC 0.18 send_rtp is a cast. Its public statistics query is a
    # same-sender ordering barrier; a matching RTP counter proves processing.
    before_count = sent_count(PeerConnection.get_stats(s.pc), s.track_id)

    if now() >= deadline do
      {:error, {:not_committed, :expired}}
    else
      packet =
        Packet.new(payload,
          sequence_number: rem(sequence, 65_536),
          timestamp: rem(tick, 4_294_967_296)
        )

      :ok = PeerConnection.send_rtp(s.pc, s.track_id, packet)
      after_count = sent_count(PeerConnection.get_stats(s.pc), s.track_id)

      if is_integer(before_count) and after_count == before_count + 1,
        do: :ok,
        else: {:error, {:outcome_unknown, :unconfirmed_submission}}
    end
  rescue
    _ -> {:error, {:outcome_unknown, :transport_failed}}
  catch
    :exit, _ -> {:error, {:outcome_unknown, :transport_failed}}
  end

  defp sent_count(stats, track) do
    Enum.find_value(stats, fn
      {_, %{type: :outbound_rtp, track_identifier: ^track, packets_sent: count}} -> count
      _ -> nil
    end)
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:connection_state_change, state}}, %{pc: pc} = s) do
    send(s.owner, {:med_ex_rtc, s.ref, state})

    if state in [:failed, :closed, :disconnected],
      do: {:stop, :normal, %{s | state: state}},
      else: {:noreply, %{s | state: state}}
  end

  def handle_info({:ex_webrtc, pc, _}, %{pc: pc} = s), do: {:noreply, s}

  def handle_info({:expiry, token}, %{expiry: {_, token, deadline}} = s) do
    if now() >= deadline, do: {:stop, :normal, s}, else: {:noreply, s}
  end

  def handle_info({:expiry, _}, s), do: {:noreply, s}
  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = s), do: {:stop, :normal, s}
  def handle_info({:DOWN, ref, :process, _, _}, %{caller_ref: ref} = s), do: {:stop, :normal, s}
  def handle_info({:EXIT, pc, _}, %{pc: pc} = s), do: {:stop, :normal, s}
  def handle_info({:EXIT, caller, _}, %{caller: caller} = s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  defp arm_expiry(s, deadline) do
    if s.expiry, do: Process.cancel_timer(elem(s.expiry, 0))
    token = make_ref()

    %{
      s
      | expiry:
          {Process.send_after(self(), {:expiry, token}, max(deadline - now(), 0)), token,
           deadline}
    }
  end

  @impl true
  def terminate(_, s) do
    if s.expiry, do: Process.cancel_timer(elem(s.expiry, 0))
    stop_pc(s.pc)
    if Process.alive?(s.owner), do: send(s.owner, {:med_ex_rtc, s.ref, :closed})
    :ok
  end

  defp stop_pc(pc) do
    monitor = Process.monitor(pc)
    Process.unlink(pc)
    if Process.alive?(pc), do: Process.exit(pc, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, ^pc, _} -> :ok
    after
      @operation_ms ->
        Process.exit(pc, :kill)
        Process.demonitor(monitor, [:flush])
    end

    :ok
  end

  defp retire(peer) do
    Process.unlink(peer.pid)
    Process.exit(peer.pid, :kill)
  end

  @doc "Validate owner and bounded ICE configuration before opening a signaling listener or peer."
  def validate_options(opts) when is_list(opts) do
    if not Keyword.keyword?(opts), do: throw(:invalid_options)
    owner = opts[:owner]
    servers = Keyword.get(opts, :ice_servers, [])
    policy = Keyword.get(opts, :ice_transport_policy, :all)

    valid =
      Keyword.keyword?(opts) and
        length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
        Enum.all?(Keyword.keys(opts), &(&1 in [:owner, :ice_servers, :ice_transport_policy])) and
        is_pid(owner) and node(owner) == node() and Process.alive?(owner) and
        policy in [:all, :relay] and
        is_list(servers) and length(servers) <= 8 and Enum.all?(servers, &ice_server?/1)

    if valid and (policy == :all or Enum.any?(servers, &turn?/1)),
      do: :ok,
      else: {:error, :invalid_owner_or_options}
  catch
    :invalid_options -> {:error, :invalid_owner_or_options}
  end

  def validate_options(_), do: {:error, :invalid_owner_or_options}

  defp ice_server?(server) when is_map(server) do
    urls = Map.get(server, :urls, Map.get(server, "urls"))
    urls = if is_binary(urls), do: [urls], else: urls

    Enum.all?(
      Map.keys(server),
      &(&1 in [:urls, :username, :credential, "urls", "username", "credential"])
    ) and
      length(Enum.map(Map.keys(server), &to_string/1) |> Enum.uniq()) == map_size(server) and
      is_list(urls) and length(urls) in 1..8 and Enum.all?(urls, &ice_url?/1) and
      Enum.all?(Map.drop(server, [:urls, "urls"]), fn {_, v} ->
        is_binary(v) and byte_size(v) <= 1024 and String.valid?(v) and
          not String.contains?(v, <<0>>)
      end)
  end

  defp ice_server?(_), do: false

  defp ice_url?(value) when is_binary(value) and byte_size(value) in 1..2048 do
    with true <- String.valid?(value),
         [scheme, address] <- String.split(value, ":", parts: 2),
         true <- scheme in ~w(stun stuns turn turns),
         {:ok,
          %URI{host: host, port: port, userinfo: nil, fragment: nil, path: path, query: query}} <-
           URI.new("https://" <> address) do
      is_binary(host) and byte_size(host) in 1..253 and port in 1..65_535 and
        path in [nil, ""] and query in [nil, "transport=udp", "transport=tcp"]
    else
      _ -> false
    end
  end

  defp ice_url?(_), do: false

  defp ice_server_options(server) do
    for key <- [:urls, :username, :credential],
        value = Map.get(server, key, Map.get(server, Atom.to_string(key))),
        not is_nil(value),
        into: %{},
        do: {key, value}
  end

  defp turn?(server) do
    urls = Map.get(server, :urls, Map.get(server, "urls")) |> List.wrap()
    Enum.any?(urls, &Regex.match?(~r/\Aturns?:/, &1))
  end

  defp offer(sdp) do
    valid =
      byte_size(sdp) in 1..@max_sdp and String.valid?(sdp) and not String.contains?(sdp, <<0>>) and
        length(Regex.scan(~r/^m=/m, sdp)) == 1 and Regex.match?(~r/^m=audio [1-9][0-9]* /m, sdp) and
        Regex.match?(~r/^a=recvonly\r?$/m, sdp) and
        not Regex.match?(~r/^a=(sendonly|sendrecv)\r?$/m, sdp) and
        Regex.match?(~r/^a=rtpmap:[0-9]+ opus\/48000\/2\r?$/mi, sdp)

    if valid, do: :ok, else: {:error, :invalid_offer}
  end

  defp valid_packet?(p, seq, tick),
    do:
      is_binary(p) and byte_size(p) in 1..1275 and
        is_integer(seq) and seq in 0..0xFFFFFFFFFFFFFFFF and is_integer(tick) and
        tick in 0..0xFFFFFFFFFFFFFFFF

  defp now, do: System.monotonic_time(:millisecond)
end
