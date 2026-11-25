defmodule MedEx.StreamWriterTest do
  use ExUnit.Case, async: true

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  alias MedEx.{IntegritySpan, SampleFrame, Serialization, StreamSpec, StreamWriter}
  alias MedEx.Storage.File, as: Store
  @moduletag :tmp_dir

  defp spec do
    spec = %StreamSpec{
      acquisition_id: "recording",
      source_ref: "credential:1",
      boot_id: "boot",
      stream_id: "ecg",
      source_epoch: 0,
      descriptor_ref: String.duplicate("a", 64),
      modality: "medex:ecg",
      encoding: :s16le,
      sample_rate: {250, 1},
      channels: [%{id: "II", label: "II", unit: "uV", calibration: :unknown}],
      capabilities: %{
        encodings: [:s16le],
        max_frame_samples: 32,
        max_payload_bytes: 64,
        commands: [],
        replay: :durable_spool
      }
    }

    %{spec | descriptor_ref: Serialization.descriptor_ref(spec)}
  end

  defp frame(seq, sample, epoch \\ 0),
    do: %SampleFrame{
      stream_id: "ecg",
      source_epoch: 0,
      descriptor_ref: spec().descriptor_ref,
      sequence: seq,
      first_sample: sample,
      sample_count: 2,
      config_epoch: epoch,
      payload: <<seq::little-16, 999::little-16>>
    }

  defp start(dir, opts \\ []),
    do:
      StreamWriter.start_link(
        Keyword.merge([owner: self(), stream: spec(), fence: "f1", artifact_dir: dir], opts)
      )

  defp recover(dir, opts \\ []),
    do: Store.recover(dir, Keyword.merge([stream: spec(), fence: "f1"], opts))

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  test "owner, fence, accepted versus durable, exact replay and immutable final bytes", %{
    tmp_dir: dir
  } do
    {:ok, w} = start(dir)
    assert {:error, :writer_active} = recover(dir)

    assert {:error, :not_owner} =
             Task.async(fn -> StreamWriter.push(w, frame(0, 0)) end) |> Task.await()

    assert {:error, :stale_fence} = StreamWriter.push(w, "stale", frame(0, 0))
    assert {:error, {:replay, 0, 0}} = StreamWriter.push(w, frame(1, 0))
    assert {:ok, a} = StreamWriter.push(w, frame(0, 0))
    assert {a.accepted_sample, a.durable_sample} == {2, 0}
    assert {:ok, ^a} = StreamWriter.push(w, frame(0, 0))
    assert {:ok, d} = StreamWriter.checkpoint(w)
    assert d.durable_sample == 2
    assert {:ok, ^d} = StreamWriter.push(w, frame(0, 0))
    assert {:ok, i} = StreamWriter.finish(w)
    assert i.terminal == :finished
    assert [seg] = i.segments
    assert Store.read_segment(dir, seg) == {:ok, frame(0, 0).payload}
    assert {:ok, result} = recover(dir, known_receipt: d)
    assert result.index == i and result.sealed and result.index_digest == Serialization.digest(i)

    assert File.read!(Path.join(dir, result.index_digest <> ".index.mej1")) ==
             Serialization.bytes(i)

    assert {:error, :unverified_receipt} = recover(dir, known_receipt: %{d | durable_sample: 100})
  end

  test "idle timer grants durable progress; explicit gap and configuration boundaries do not add bytes",
       %{tmp_dir: dir} do
    {:ok, w} = start(dir, limits: %{checkpoint_ms: 25})
    {:ok, _} = StreamWriter.push(w, frame(0, 0))
    assert_receive {:med_ex_durable, ^w, %{durable_sequence: 1}}

    gap = %{
      id: "gap1",
      first_sequence: 1,
      next_sequence: 3,
      irreversible: true,
      span: %IntegritySpan{
        stream_id: "ecg",
        source_epoch: 0,
        first_sample: 2,
        end_sample: 12,
        code: :source_gap,
        source: "gateway",
        context: %{"reason" => "spool_exhausted"}
      }
    }

    assert {:ok, r} = StreamWriter.record_gap(w, gap)
    assert r.durable_sample == 12
    assert {:ok, ^r} = StreamWriter.record_gap(w, gap)
    assert {:ok, _} = StreamWriter.push(w, frame(3, 12, :unknown))
    assert {:ok, _} = StreamWriter.push(w, frame(4, 14, 2))
    assert {:ok, i} = StreamWriter.finish(w)

    assert Enum.map(i.segments, &{&1.first_sample, &1.end_sample, &1.config_epoch}) == [
             {0, 2, 0},
             {12, 14, :unknown},
             {14, 16, 2}
           ]

    assert Enum.map(i.spans, & &1.code) == [:source_gap, :configuration_unknown]
    assert i.gaps == [gap]
  end

  test "frozen prefix import reissues current authority and refuses a live or changed predecessor",
       %{tmp_dir: root} do
    old = Path.join(root, "old")
    new = Path.join(root, "new")
    {:ok, w} = start(old, limits: %{pending_frames: 1})
    {:ok, ack} = StreamWriter.push(w, frame(0, 0))
    pred = %{artifact_dir: old, receipt: ack}
    assert {:error, {:not_committed, :writer_active}} = start(new, fence: "f2", predecessor: pred)
    kill(w)
    File.write!(Path.join(old, "stream.mejournal"), "ME", [:append])
    original = File.read!(Path.join(old, "stream.mejournal"))
    assert {:ok, %{torn_tail: true, sealed: false}} = recover(old, known_receipt: ack)
    {:ok, next} = start(new, fence: "f2", predecessor: pred)
    assert {:ok, current} = StreamWriter.push(next, frame(0, 0))
    assert {current.durable_sample, current.fence} == {2, "f2"}
    refute current.journal_id == ack.journal_id
    assert File.read!(Path.join(old, "stream.mejournal")) == original
    File.rm_rf!(old)
    assert {:ok, _} = StreamWriter.push(next, frame(1, 2))
    assert {:ok, index} = StreamWriter.finish(next)
    assert Enum.map(index.segments, & &1.first_sequence) == [0, 1]
    assert {:ok, %{index: ^index}} = recover(new, fence: "f2", known_receipt: current)
    assert {:error, :unverified_receipt} = recover(new, fence: "f2", known_receipt: ack)

    assert {:error, _} =
             start(Path.join(root, "third"),
               fence: "f3",
               predecessor: %{artifact_dir: new, receipt: current}
             )
  end

  test "conflicting duplicate quarantines the attempt", %{tmp_dir: dir} do
    {:ok, w} = start(dir)
    {:ok, _} = StreamWriter.push(w, frame(0, 0))

    assert {:error, :duplicate_conflict} =
             StreamWriter.push(w, %{frame(0, 0) | payload: <<9, 9, 9, 9>>})

    assert {:ok,
            %{
              index: %{
                terminal: :failed,
                terminal_reason: "duplicate_conflict",
                spans: [
                  %{
                    code: :duplicate_conflict,
                    event_ids: ["0"],
                    context: %{"attempted_sha256" => a, "stored_sha256" => b}
                  }
                ]
              }
            }} = recover(dir)

    refute a == b
  end

  test "incomplete bytes without any durable receipt remain unknown after hard kill", %{
    tmp_dir: dir
  } do
    {:ok, w} = start(dir)
    {:ok, accepted} = StreamWriter.push(w, frame(0, 0))
    kill(w)
    File.write!(Path.join(dir, ".orphan.part"), <<1>>)

    assert {:ok, %{receipt: %{durable_sample: 0}, index: %{terminal: :interrupted, segments: []}}} =
             recover(dir, known_receipt: accepted)
  end

  test "rejects corrupt journal interior, missing and overwritten chunk", %{tmp_dir: dir} do
    {:ok, w} = start(dir, limits: %{pending_frames: 1})
    {:ok, receipt} = StreamWriter.push(w, frame(0, 0))
    {:ok, sealed} = StreamWriter.finish(w)
    [seg] = sealed.segments
    path = Path.join(dir, seg.key)
    original = File.read!(path)
    File.rm!(path)
    assert {:error, _} = recover(dir)
    File.write!(path, :binary.copy(<<0>>, seg.byte_size))
    assert {:error, :invalid_object} = recover(dir)
    File.write!(path, original)
    journal = Path.join(dir, "stream.mejournal")
    <<head::binary-size(50), byte, rest::binary>> = File.read!(journal)
    File.write!(journal, <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)
    assert {:error, :journal_chain} = recover(dir, known_receipt: receipt)
  end

  test "storage crash cuts preserve the acknowledged prefix or recover the complete uncertain append",
       %{tmp_dir: root} do
    for cut <- [
          :before_object_sync,
          :after_object_sync,
          :after_object_install,
          :before_journal_append,
          :after_journal_append,
          :after_journal_sync,
          :before_index_install,
          :after_index_install
        ] do
      dir = Path.join(root, Atom.to_string(cut))
      control = :atomics.new(1, [])

      hook = fn stage ->
        if stage == cut and :atomics.get(control, 1) == 1, do: {:error, {:cut, stage}}, else: :ok
      end

      {:ok, w} = start(dir, fault_hook: hook)
      {:ok, _} = StreamWriter.push(w, frame(0, 0))
      {:ok, d} = StreamWriter.checkpoint(w)
      {:ok, _} = StreamWriter.push(w, frame(1, 2))
      :atomics.put(control, 1, 1)
      assert {:error, _} = StreamWriter.finish(w)
      if Process.alive?(w), do: kill(w)
      assert {:ok, result} = recover(dir, known_receipt: d)
      assert result.receipt.durable_sample in [2, 4]

      if cut in [:before_index_install, :after_index_install] do
        assert {:ok, %{sealed: true, index: %{terminal: :finished}}} =
                 Store.reconcile_index(dir, stream: spec(), fence: "f1", known_receipt: d)
      else
        refute result.sealed
      end
    end
  end

  test "bounded per-stream disk stall leaves sibling receipt and unrelated process responsive", %{
    tmp_dir: dir
  } do
    parent = self()
    stall = :atomics.new(1, [])

    owner =
      spawn(fn ->
        hook = fn
          :before_object_sync ->
            if :atomics.add_get(stall, 1, 1) == 1 do
              send(parent, {:stalled, self()})

              receive do
                :release -> :ok
              end
            else
              :ok
            end

          _ ->
            :ok
        end

        {:ok, w} = start(Path.join(dir, "slow"), fault_hook: hook)
        {:ok, _} = StreamWriter.push(w, frame(0, 0))
        send(parent, {:slow_result, StreamWriter.checkpoint(w)})
      end)

    assert_receive {:stalled, slow_writer}
    {:ok, other} = start(Path.join(dir, "fast"), limits: %{pending_frames: 1})
    assert {:ok, %{durable_sample: 2}} = StreamWriter.push(other, frame(0, 0))
    assert Process.alive?(owner)
    send(slow_writer, :release)
    assert_receive {:slow_result, {:ok, %{durable_sample: 2}}}
    assert {:ok, _} = StreamWriter.interrupt(other, :disconnected)
  end

  test "manual checkpoint mode disables timer flushes and commits only on explicit owner calls",
       %{
         tmp_dir: dir
       } do
    {:ok, w} = start(dir, limits: %{checkpoint_ms: :manual})
    assert {:ok, accepted} = StreamWriter.push(w, frame(0, 0))
    assert accepted.accepted_sequence == 1
    assert accepted.durable_sequence == 0
    refute_receive {:med_ex_durable, ^w, _}, 350

    assert {:ok, current} = StreamWriter.receipt(w)
    assert current.durable_sequence == 0

    assert {:ok, durable} = StreamWriter.checkpoint(w)
    assert durable.durable_sequence == 1
    assert durable.durable_sample == 2

    assert {:ok, index} = StreamWriter.finish(w)
    assert index.next_sequence == 1
  end
end
