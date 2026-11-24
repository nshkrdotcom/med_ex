defmodule MedEx.PreviewSessionTest do
  use ExUnit.Case, async: true

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  alias MedEx.{Capture, PreviewSession}

  @moduletag :tmp_dir
  @pcm :binary.copy(<<42, 0>>, 960)

  test "finish commits while native startup is pending and stops its entire tree", %{
    tmp_dir: dir
  } do
    capture = gated_capture(dir)
    subscribe_from_peer(capture)
    assert_receive {:starting, session, supervisor, pipeline}, 5_000
    refs = monitor_all([session, supervisor, pipeline])

    assert :ok = Capture.push(capture, 0, @pcm)
    assert {:ok, evidence} = Capture.finish(capture)
    assert evidence.sample_count == 960
    assert File.ls!(dir) == [evidence.artifact_key]
    assert_receive {:subscribed, _, {:error, :preview_unavailable}}
    assert_down(refs)
  end

  test "normal producer exit aborts pending preview and removes the part", %{tmp_dir: dir} do
    producer =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    {:ok, capture} = Capture.start_link(Keyword.put(capture_opts(dir), :owner, producer))
    capture_ref = Process.monitor(capture)
    subscribe_from_peer(capture)
    assert_receive {:starting, session, supervisor, pipeline}, 5_000
    refs = monitor_all([session, supervisor, pipeline])

    send(producer, :done)
    assert_receive {:DOWN, ^capture_ref, :process, ^capture, :normal}, 5_000
    assert_down(refs)
    assert File.ls!(dir) == []
  end

  test "subscriber death during startup releases the linked encoder tree", %{tmp_dir: dir} do
    capture = gated_capture(dir)
    peer = subscribe_from_peer(capture)
    assert_receive {:starting, session, supervisor, pipeline}, 5_000
    refs = monitor_all([session, supervisor, pipeline])

    Process.exit(peer, :kill)
    assert_down(refs)
    assert :ok = Capture.push(capture, 0, @pcm)
    assert {:ok, _} = Capture.finish(capture)
  end

  test "hard capture death during startup releases the linked encoder tree", %{tmp_dir: dir} do
    capture = gated_capture(dir)
    Process.unlink(capture)
    subscribe_from_peer(capture)
    assert_receive {:starting, session, supervisor, pipeline}, 5_000
    refs = monitor_all([session, supervisor, pipeline])

    Process.exit(capture, :kill)
    assert_down(refs)
  end

  test "an encoder start error is returned to the subscriber and writing continues", %{
    tmp_dir: dir
  } do
    opts = Keyword.put(capture_opts(dir), :start_preview_encoder, fn -> {:error, :busy} end)
    {:ok, capture} = Capture.start_link(opts)
    assert {:error, :preview_unavailable} = Capture.subscribe(capture)
    assert :ok = Capture.push(capture, 0, @pcm)
    assert {:ok, _} = Capture.finish(capture)
  end

  test "startup failure or timeout leaves the producer able to finish", %{tmp_dir: dir} do
    capture = gated_capture(dir)
    subscribe_from_peer(capture)
    assert_receive {:starting, first, supervisor, pipeline}, 5_000
    refs = monitor_all([first, supervisor, pipeline])
    Process.exit(first, :kill)
    assert_receive {:subscribed, _, {:error, :preview_unavailable}}
    assert_down(refs)

    subscribe_from_peer(capture)
    assert_receive {:starting, second, supervisor, pipeline}, 5_000
    refs = monitor_all([second, supervisor, pipeline])
    assert_receive {:subscribed, _, {:error, :preview_unavailable}}, 6_000
    assert_down(refs)

    assert :ok = Capture.push(capture, 0, @pcm)
    assert {:ok, _} = Capture.finish(capture)
  end

  test "an expired request cannot displace an active peer after Capture resumes", %{
    tmp_dir: dir
  } do
    capture = gated_capture(dir)
    active = subscribe_from_peer(capture)
    assert_receive {:starting, session, _, _}, 5_000
    send(session, :release_start)
    assert_receive {:subscribed, ^active, :ok}, 5_000
    :sys.suspend(capture)

    peer =
      try do
        peer = subscribe_from_peer(capture)
        assert_receive {:subscribed, ^peer, {:error, :preview_unavailable}}, 7_000
        peer
      after
        :sys.resume(capture)
      end

    send(peer, :demand_twice)
    assert_receive {:demanded, ^peer}
    assert %{preview: %{session: ^session, subscriber: ^active}} = :sys.get_state(capture)
    assert :ok = Capture.push(capture, 0, @pcm)
    assert_receive {:peer_message, ^active, {:med_ex_preview, ^capture, 0, _}}, 5_000
    refute_received {:peer_message, ^active, {:med_ex_preview_replaced, ^capture}}
    assert {:ok, _} = Capture.finish(capture)
  end

  test "replacement retires a pending start and ignores old readiness, completion and death", %{
    tmp_dir: dir
  } do
    capture = gated_capture(dir)
    first = subscribe_from_peer(capture)
    assert_receive {:starting, old, supervisor, pipeline}, 5_000
    refs = monitor_all([old, supervisor, pipeline])
    second = subscribe_from_peer(capture)
    assert_receive {:subscribed, ^first, {:error, :preview_unavailable}}
    assert_receive {:peer_message, ^first, {:med_ex_preview_replaced, ^capture}}
    assert_receive {:starting, new, _, _}, 5_000
    assert_down(refs)

    send(capture, {:preview_ready, old})
    send(capture, {:preview_encoded, old, 0, <<"stale">>})
    send(capture, {:preview_start_timeout, old})
    assert %{preview: %{session: ^new, phase: {:starting, _, _}}} = :sys.get_state(capture)
    send(new, :release_start)
    assert_receive {:subscribed, ^second, :ok}, 5_000
    :erlang.suspend_process(new)

    try do
      assert :ok = Capture.push(capture, 0, @pcm)
      send(capture, {:preview_encoded, old, 0, <<"stale">>})
      send(capture, {:EXIT, old, :shutdown})
      :sys.get_state(capture)
    after
      :erlang.resume_process(new)
    end

    assert_receive {:peer_message, ^second, {:med_ex_preview, ^capture, 0, payload}}, 5_000
    refute payload == <<"stale">>
    refute_received {:peer_message, ^second, {:med_ex_preview_failed, ^capture, _}}
    assert {:ok, _} = Capture.finish(capture)
  end

  test "busy session admits one frame despite early and duplicate demand", %{
    tmp_dir: dir
  } do
    capture = gated_capture(dir)
    peer = subscribe_from_peer(capture)
    assert_receive {:starting, session, _, _}, 5_000
    send(session, :release_start)
    assert_receive {:subscribed, ^peer, :ok}, 5_000

    :erlang.suspend_process(session)

    try do
      assert :ok = Capture.push(capture, 0, @pcm)
      send(peer, :subscribe_again)
      assert_receive {:subscribed, ^peer, :ok}
      send(peer, :demand_twice)
      assert_receive {:demanded, ^peer}

      for frame <- 1..16 do
        assert :ok = Capture.push(capture, frame * 960, @pcm)
      end

      {:messages, mailbox} = Process.info(session, :messages)
      assert [{:pcm, 0, @pcm}] == Enum.filter(mailbox, &match?({:pcm, _, _}, &1))
    after
      :erlang.resume_process(session)
    end

    assert_receive {:peer_message, ^peer, {:med_ex_preview, ^capture, 0, _}}, 5_000
    # A stranger's demand cannot consume the real peer's backpressure.
    Capture.demand(capture)
    assert :ok = Capture.push(capture, 17 * 960, @pcm)
    send(peer, :demand_twice)
    assert_receive {:demanded, ^peer}
    assert :ok = Capture.push(capture, 18 * 960, @pcm)
    assert :ok = Capture.push(capture, 19 * 960, @pcm)
    index = 18 * 960
    assert_receive {:peer_message, ^peer, {:med_ex_preview, ^capture, ^index, _}}, 5_000
    assert {:ok, evidence} = Capture.finish(capture)
    assert evidence.sample_count == 20 * 960
  end

  test "unexpected normal pipeline shutdown reports failure and a peer can subscribe again", %{
    tmp_dir: dir
  } do
    capture = gated_capture(dir)
    peer = subscribe_from_peer(capture)
    assert_receive {:starting, first, _, pipeline}, 5_000
    send(first, :release_start)
    assert_receive {:subscribed, ^peer, :ok}, 5_000
    assert :ok = Membrane.Pipeline.terminate(pipeline)
    assert_receive {:peer_message, ^peer, {:med_ex_preview_failed, ^capture, _}}, 5_000

    send(peer, :subscribe_again)
    assert_receive {:starting, second, _, _}, 5_000
    send(second, :release_start)
    assert_receive {:subscribed, ^peer, :ok}, 5_000
    assert :ok = Capture.push(capture, 0, @pcm)
    assert_receive {:peer_message, ^peer, {:med_ex_preview, ^capture, 0, _}}, 5_000
    assert {:ok, _} = Capture.finish(capture)
  end

  test "supervised shutdown cleans the part file and cancels an unfinished preview", %{
    tmp_dir: dir
  } do
    capture = start_supervised!({Capture, capture_opts(dir)})
    subscribe_from_peer(capture)
    assert_receive {:starting, session, supervisor, pipeline}, 5_000
    refs = monitor_all([session, supervisor, pipeline])

    assert :ok = Capture.push(capture, 0, @pcm)
    assert :ok = stop_supervised(Capture)
    assert File.ls!(dir) == []
    assert_down(refs)
  end

  defp gated_capture(dir) do
    {:ok, capture} = Capture.start_link(capture_opts(dir))
    capture
  end

  defp capture_opts(dir) do
    test = self()

    # Pause the real start operation after its supervisor is linked, before the
    # caller receives its PID. This exercises cancellation across the ownership handoff.
    start_encoder = fn ->
      {:ok, supervisor, pipeline} = PreviewSession.start_encoder()
      send(test, {:starting, self(), supervisor, pipeline})

      receive do
        :release_start -> {:ok, supervisor, pipeline}
      end
    end

    [
      owner: test,
      acquisition_id: "preview",
      artifact_dir: dir,
      start_preview_encoder: start_encoder
    ]
  end

  defp subscribe_from_peer(capture) do
    test = self()

    spawn(fn ->
      ref = Process.monitor(test)
      send(test, {:subscribed, self(), Capture.subscribe(capture)})
      peer_loop(test, capture, ref)
    end)
  end

  defp peer_loop(test, capture, ref) do
    receive do
      {:DOWN, ^ref, :process, ^test, _} ->
        :ok

      :subscribe_again ->
        send(test, {:subscribed, self(), Capture.subscribe(capture)})
        peer_loop(test, capture, ref)

      :demand_twice ->
        Capture.demand(capture)
        Capture.demand(capture)
        # Barrier for the two casts from this subscriber.
        :sys.get_state(capture)
        send(test, {:demanded, self()})
        peer_loop(test, capture, ref)

      message ->
        send(test, {:peer_message, self(), message})
        peer_loop(test, capture, ref)
    end
  end

  defp monitor_all(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  defp assert_down(refs) do
    Enum.each(refs, fn {pid, ref} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end)
  end
end
