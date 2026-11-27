defmodule MedEx.RTC.ProviderTest do
  use ExUnit.Case, async: false
  require Logger
  alias ExWebRTC.{PeerConnection, SessionDescription}
  alias MedEx.RTC.Provider

  # Independently supplied RFC 6716 Opus silence; this package has no encoder
  # dependency and this test does not imply PCM/codec qualification.
  @packet <<0xF8, 0xFF, 0xFE>>

  test "supported concrete exports and dependency closure remain independent" do
    internal =
      GenServer.behaviour_info(:callbacks) ++
        [child_spec: 1, module_info: 0, module_info: 1, __info__: 1, __struct__: 0, __struct__: 1]

    assert Enum.sort(Provider.__info__(:functions) -- internal) ==
             Enum.sort(answer: 2, send_opus: 5, close: 1, peer_ref: 1, validate_options: 1)

    deps = Mix.Project.config()[:deps] |> Enum.map(&elem(&1, 0))
    refute :med_ex in deps
    refute :med_ex_opus in deps
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp receiver(opts \\ []) do
    {:ok, pc} =
      PeerConnection.start_link(
        Keyword.merge([ice_servers: [], audio_codecs: [:opus], video_codecs: []], opts)
      )

    on_exit(fn -> stop(pc) end)
    {:ok, _} = PeerConnection.add_transceiver(pc, :audio, direction: :recvonly)
    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    assert_receive {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}}, 6000
    {pc, PeerConnection.get_local_description(pc).sdp}
  end

  defp connected(opts \\ []) do
    {receiver, offer} = receiver(opts)
    assert {:ok, peer, answer} = Provider.answer(offer, Keyword.put(opts, :owner, self()))
    assert peer.pid in elem(Process.info(self(), :links), 1)
    ref = Provider.peer_ref(peer)
    assert is_reference(ref)
    assert Regex.scan(~r/^m=/m, answer) |> length() == 1
    assert String.contains?(answer, "a=sendonly")

    :ok =
      PeerConnection.set_remote_description(receiver, %SessionDescription{
        type: :answer,
        sdp: answer
      })

    assert_receive {:med_ex_rtc, ^ref, :connected}, 10_000
    assert_receive {:ex_webrtc, ^receiver, {:connection_state_change, :connected}}, 10_000
    {peer, receiver}
  end

  test "concrete transport receives Opus with wrapping sequence and elapsed media time" do
    {peer, receiver} = connected()
    assert :ok = Provider.send_opus(peer, @packet, 65_535, 4_294_967_000, now() + 5000)

    assert_receive {:ex_webrtc, ^receiver,
                    {:rtp, _, nil,
                     %{sequence_number: 65_535, timestamp: 4_294_967_000, payload: @packet}}},
                   2000

    # A dropped preview frame advances elapsed media time, but not emitted count.
    assert :ok = Provider.send_opus(peer, @packet, 65_536, 4_294_968_920, now() + 5000)

    assert_receive {:ex_webrtc, ^receiver,
                    {:rtp, _, nil, %{sequence_number: 0, timestamp: 1624, payload: @packet}}},
                   2000

    assert :ok = Provider.close(peer)
    assert :ok = Provider.close(peer)
  end

  test "owner, malformed packet and expired deadline fail before any packet" do
    {peer, receiver} = connected()

    assert {:error, :not_owner} =
             Task.async(fn -> Provider.send_opus(peer, @packet, 0, 0, now() + 1000) end)
             |> Task.await()

    assert {:error, :not_owner} = Task.async(fn -> Provider.close(peer) end) |> Task.await()

    assert {:error, {:not_committed, :invalid_packet}} =
             Provider.send_opus(peer, <<>>, 0, 0, now() + 1000)

    assert {:error, {:not_committed, :invalid_packet}} =
             Provider.send_opus(peer, @packet, -1, 0, now() + 1000)

    assert {:error, {:not_committed, :expired}} =
             Provider.send_opus(peer, @packet, 0, 0, now() - 1)

    refute_receive {:ex_webrtc, ^receiver, {:rtp, _, _, _}}, 100
    assert :ok = Provider.close(peer)
  end

  test "a send queued past its deadline retires and cannot emit after resumption" do
    {peer, receiver} = connected()
    :ok = :sys.suspend(peer.pid)
    monitor = Process.monitor(peer.pid)

    assert {:error, {:outcome_unknown, :rtc_call_failed}} =
             Provider.send_opus(peer, @packet, 0, 0, now() + 30)

    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 1000
    refute_receive {:ex_webrtc, ^receiver, {:rtp, _, _, _}}, 200
    assert :ok = Provider.close(peer)
  end

  test "deadline expiry and owner death close concrete ExWebRTC children" do
    {peer, _receiver} = connected()
    pc = :sys.get_state(peer.pid).pc
    monitor = Process.monitor(pc)
    assert :ok = Provider.send_opus(peer, @packet, 0, 0, now() + 150)
    assert_receive {:DOWN, ^monitor, :process, ^pc, _}, 2000

    {_, offer} = receiver()
    test = self()

    owner =
      spawn(fn ->
        {:ok, owned, _} = Provider.answer(offer, owner: self(), ice_servers: [])
        send(test, {:owned, owned, :sys.get_state(owned.pid).pc})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:owned, owned, child}, 12_000
    wrapper_monitor = Process.monitor(owned.pid)
    child_monitor = Process.monitor(child)
    send(owner, :done)
    assert_receive {:DOWN, ^wrapper_monitor, :process, _, :normal}, 2000
    assert_receive {:DOWN, ^child_monitor, :process, _, _}, 2000
  end

  test "distinct caller abandonment and failed negotiation leave no peer behind" do
    {_, offer} = receiver()
    test = self()

    caller =
      spawn(fn ->
        result = Provider.answer(offer, owner: test, ice_servers: [])
        send(test, {:answer, result})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:answer, {:ok, peer, _}}, 12_000
    child = :sys.get_state(peer.pid).pc
    monitor = Process.monitor(child)
    send(caller, :done)
    assert_receive {:DOWN, ^monitor, :process, ^child, _}, 2000

    before = MapSet.new(PeerConnection.get_all_running())

    malformed =
      "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=recvonly\r\na=rtpmap:111 opus/48000/2\r\n"

    assert {:error, _} = Provider.answer(malformed, owner: self(), ice_servers: [])
    assert MapSet.new(PeerConnection.get_all_running()) == before
  end

  test "expected negotiation refusal preserves its public reason and omits private crash reports" do
    before = MapSet.new(PeerConnection.get_all_running())
    sentinel = "rtc-private-startup-sentinel"

    malformed =
      "v=0\r\ns=#{sentinel}\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n" <>
        "a=recvonly\r\na=rtpmap:111 opus/48000/2\r\n"

    test = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {caller, monitor} =
          spawn_monitor(fn ->
            send(test, {:refusal, self(), Provider.answer(malformed, owner: self())})
            send(test, {:caller_flags, Process.info(self(), :trap_exit)})

            receive do
              :done -> :ok
            end
          end)

        assert_receive {:refusal, ^caller, {:error, :negotiation_failed}}, 12_000
        assert_receive {:caller_flags, {:trap_exit, false}}
        assert Process.alive?(caller)
        send(caller, :done)
        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
        Logger.warning("safe_rtc_refusal_diagnostic")
      end)

    assert MapSet.new(PeerConnection.get_all_running()) == before
    assert log =~ "safe_rtc_refusal_diagnostic"
    refute log =~ sentinel
    refute log =~ "CRASH REPORT"
    refute log =~ "crasher:"
  end

  test "SDP and ICE configuration reject invalid surfaces before opening a peer" do
    for sdp <- ["", "not SDP", :binary.copy("a", 65_537), <<0>>] do
      assert {:error, :invalid_offer} = Provider.answer(sdp, owner: self())
    end

    assert {:error, :invalid_owner_or_options} = Provider.answer("v=0", owner: nil)

    assert {:error, :invalid_owner_or_options} =
             Provider.answer("v=0", owner: self(), arbitrary: true)

    assert {:error, :invalid_owner_or_options} =
             Provider.answer("v=0", owner: self(), ice_transport_policy: :relay)

    assert {:error, :invalid_owner_or_options} =
             Provider.answer("v=0", owner: self(), ice_servers: [%{urls: "https://invalid"}])

    {_, offer} = receiver()

    assert {:error, :invalid_offer} =
             Provider.answer(String.replace(offer, "a=recvonly", "a=sendrecv"), owner: self())

    assert {:error, :invalid_offer} =
             Provider.answer(offer <> "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n", owner: self())
  end

  test "one ICE validator accepts runtime JSON keys and rejects ambiguous or malformed URLs" do
    assert :ok =
             Provider.validate_options(
               owner: self(),
               ice_servers: [
                 %{
                   "urls" => ["stun:localhost:3478", "turns:[::1]:5349?transport=tcp"],
                   "username" => "fixture",
                   "credential" => "fixture-secret"
                 }
               ],
               ice_transport_policy: :relay
             )

    assert {:error, :invalid_owner_or_options} =
             Provider.validate_options(
               owner: self(),
               ice_servers: [%{:urls => "stun:localhost", "urls" => "stun:localhost"}]
             )

    for url <- [
          "stun:",
          "stun:host:0",
          "turn:host:65536",
          "turn:user@host",
          "turn:host/path",
          "turn:host?secret=value",
          "https://host",
          "stun:host#fragment"
        ] do
      assert {:error, :invalid_owner_or_options} =
               Provider.validate_options(owner: self(), ice_servers: [%{"urls" => url}])
    end
  end

  @tag :turn
  test "configured relay-only peers transmit using TURN" do
    url = System.fetch_env!("MED_EX_RTC_TURN_URL")
    username = System.fetch_env!("MED_EX_RTC_TURN_USERNAME")
    credential = System.fetch_env!("MED_EX_RTC_TURN_CREDENTIAL")

    options = [
      ice_servers: [%{urls: url, username: username, credential: credential}],
      ice_transport_policy: :relay
    ]

    {peer, receiver} = connected(options)
    assert :ok = Provider.send_opus(peer, @packet, 0, 0, now() + 5000)
    assert_receive {:ex_webrtc, ^receiver, {:rtp, _, _, %{payload: @packet}}}, 5000
    :ok = Provider.close(peer)
  end

  defp stop(pid) do
    Process.unlink(pid)
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end
end
