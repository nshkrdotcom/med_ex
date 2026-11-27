defmodule MedEx.StreamWriterTest do
  use ExUnit.Case, async: true
  alias MedEx.CaptureFixture, as: F
  alias MedEx.{IntegritySpan, Receipt, Serialization, StreamWriter}
  alias MedEx.Storage.{File, Terminal}

  setup do
    fixture = F.root()
    on_exit(fn -> F.cleanup(fixture) end)
    fixture
  end

  test "owner and explicit fence precede every effect; durable vs volatile and replay", f do
    {:ok, writer} = F.start(f)

    assert {:error, :not_owner} =
             Task.async(fn -> StreamWriter.push(writer, "f1", F.frame(0), 1000) end)
             |> Task.await()

    for op <- [:checkpoint, :finish, :receipt, :stats] do
      assert {:error, :stale_fence} = apply(StreamWriter, op, [writer, "stale", 1000])
    end

    assert {:error, :writer_active} = F.recover(f)
    assert {:ok, accepted} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    refute Receipt.durable?(accepted)
    assert accepted.durable_sample == 0 and accepted.accepted_sample == 960
    assert {:ok, ^accepted} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    assert {:ok, durable} = StreamWriter.checkpoint(writer, "f1", 1000)
    assert Receipt.durable?(durable)
    assert {:ok, ^durable} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    assert {:ok, %Terminal{} = terminal} = StreamWriter.finish(writer, "f1", 5000)
    assert terminal.receipt.journal_generation == durable.journal_generation + 1
    assert {:ok, ^terminal} = StreamWriter.finish(writer, "f1", 1000)

    for op <- [{:push, [F.frame(1)]}, {:record_gap, [%{}]}, {:checkpoint, []}] do
      {name, args} = op
      assert {:error, :sealed} = apply(StreamWriter, name, [writer, "f1"] ++ args ++ [1000])
    end

    assert {:ok, prefix} = F.recover(f, known_receipt: durable)
    assert Receipt.exact_prefix?(terminal.receipt, prefix)
    assert {:ok, index} = F.verified(prefix)
    assert {:ok, bytes} = File.read_verified_segment(index, 0, F.expected(prefix))
    assert bytes == F.frame(0).payload
  end

  test "sample-only gap is explicit and does not consume a frame sequence", f do
    {:ok, writer} = F.start(f)

    gap = %{
      id: "gap1",
      first_sequence: 0,
      next_sequence: 0,
      irreversible: true,
      span: %IntegritySpan{
        stream_id: "audio",
        source_epoch: 0,
        code: :source_gap,
        source: "device",
        first_sample: 0,
        end_sample: 20
      }
    }

    assert {:ok, r} = StreamWriter.record_gap(writer, "f1", gap, 1000)
    assert {r.durable_sequence, r.durable_sample} == {0, 20}
    assert {:ok, ^r} = StreamWriter.record_gap(writer, "f1", gap, 1000)
    assert {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0, 20), 1000)
    assert {:ok, terminal} = StreamWriter.finish(writer, "f1", 5000)
    assert terminal.index.gaps == [gap]
  end

  test "unknown outcome retires instead of reusing state; verified recovery retains commit", f do
    counter = :atomics.new(1, [])

    Process.put({StreamWriter, :fault_hook}, fn stage ->
      if stage == :after_journal_sync and :atomics.get(counter, 1) == 1,
        do: {:error, :cut},
        else: :ok
    end)

    {:ok, writer} = F.start(f)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    :atomics.put(counter, 1, 1)
    ref = Process.monitor(writer)
    assert {:error, {:outcome_unknown, _}} = StreamWriter.checkpoint(writer, "f1", 1000)
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
    assert {:ok, prefix} = F.recover(f)
    assert prefix.receipt.durable_sample == 960
  end

  test "manual owner loss does not flush accepted backlog", f do
    test = self()

    owner =
      spawn(fn ->
        {:ok, writer} = F.start(f)
        {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
        send(test, {:writer, writer})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:writer, writer}
    ref = Process.monitor(writer)
    send(owner, :exit)
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
    assert {:ok, prefix} = F.recover(f)
    assert prefix.receipt.durable_sequence == 0
    refute prefix.terminal_recorded
  end

  test "verified quiescent predecessor imports exactly and keeps old bytes immutable", f do
    {:ok, writer} = F.start(f)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    {:ok, durable} = StreamWriter.checkpoint(writer, "f1", 1000)
    F.retire(writer)
    assert {:ok, prefix} = F.recover(f, known_receipt: durable)
    original = Elixir.File.read!(Path.join(f.dir, "stream.mejournal"))
    new = Path.join(f.root, "successor")
    assert {:ok, successor} = F.start(f, artifact_dir: new, fence: "f2", predecessor: prefix)
    assert {:ok, r} = StreamWriter.receipt(successor, "f2", 1000)
    assert r.durable_sample == durable.durable_sample and r.journal_generation == 1
    assert r.fence == "f2" and r.journal_id != durable.journal_id
    assert Elixir.File.read!(Path.join(f.dir, "stream.mejournal")) == original
    assert {:ok, _} = StreamWriter.push(successor, "f2", F.frame(1), 1000)
    assert {:ok, terminal} = StreamWriter.finish(successor, "f2", 5000)
    assert terminal.receipt.durable_sample == 1920
  end

  test "small frame budget reserves a terminal and refuses N+1 without data loss", f do
    {:ok, writer} = F.start(f, limits: %{frames: 2, checkpoint_ms: :manual})
    for seq <- 0..1, do: assert({:ok, _} = StreamWriter.push(writer, "f1", F.frame(seq), 1000))

    assert {:error, {:not_committed, {:capacity, :frame_limit}}} =
             StreamWriter.push(writer, "f1", F.frame(2), 1000)

    assert {:ok, terminal} = StreamWriter.finish(writer, "f1", 5000)
    assert terminal.receipt.durable_sequence == 2
  end

  test "unanswered authorization cannot retire or later mutate a suspended writer", f do
    {:ok, writer} = F.start(f)
    :ok = :sys.suspend(writer)

    assert {:error, {:not_committed, :writer_authorization_unavailable}} =
             Task.async(fn -> StreamWriter.push(writer, "f1", F.frame(0), 30) end) |> Task.await()

    assert {:error, {:not_committed, :writer_authorization_unavailable}} =
             StreamWriter.checkpoint(writer, "stale", 30)

    assert Process.alive?(writer)
    :ok = :sys.resume(writer)

    assert {:ok, %{accepted_sequence: 0, durable_sequence: 0}} =
             StreamWriter.receipt(writer, "f1", 1000)

    assert {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    expired = System.monotonic_time(:millisecond) - 1

    assert {:error, {:not_committed, :expired}} =
             GenServer.call(writer, {"f1", :checkpoint, expired})

    assert {:ok, %{accepted_sequence: 1, durable_sequence: 0}} =
             StreamWriter.receipt(writer, "f1", 1000)

    F.retire(writer)
    assert {:ok, %{receipt: %{durable_sequence: 0}}} = F.recover(f)
  end

  test "conflicting replay records a truthful failed terminal", f do
    {:ok, writer} = F.start(f)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    bad = %{F.frame(0) | payload: :binary.copy(<<1, 0>>, 960)}
    assert {:error, :duplicate_conflict} = StreamWriter.push(writer, "f1", bad, 1000)
    assert {:ok, prefix} = F.recover(f)
    assert prefix.index.terminal == :failed
    assert prefix.index.terminal_reason == "duplicate_conflict"
    assert Serialization.digest(prefix.index) == prefix.index_digest
  end
end
