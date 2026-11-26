defmodule MedEx.StorageContractTest do
  use ExUnit.Case, async: true
  alias MedEx.{SampleFrame, StreamSpec, StreamWriter}
  alias MedEx.Storage.File, as: Store
  @moduletag :tmp_dir

  # Real POSIX operations followed by a deliberately invalid reply. Tests
  # receipt validation without substituting a memory store for durability.
  defmodule InvalidReceipt do
    @behaviour MedEx.Storage
    defdelegate open(opts), to: MedEx.Storage.File
    defdelegate lookup(s, kind, key), to: MedEx.Storage.File
    defdelegate usage(s), to: MedEx.Storage.File
    defdelegate seal(s, status, reason), to: MedEx.Storage.File
    defdelegate close(s), to: MedEx.Storage.File
    defdelegate recover(dir, opts), to: MedEx.Storage.File

    def commit_batch(s, batch) do
      with {:ok, next, receipt} <- MedEx.Storage.File.commit_batch(s, batch),
           do: {:ok, next, %{receipt | journal_generation: receipt.journal_generation + 1}}
    end
  end

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)

    spec = %StreamSpec{
      stream_id: "s",
      source_epoch: 3,
      acquisition_id: "a",
      source_ref: "d",
      boot_id: "b",
      descriptor_ref: String.duplicate("c", 64),
      modality: "medex:audio",
      encoding: :s16le,
      channels: [%{id: "m", label: "mic", unit: :unknown, calibration: :unknown}],
      sample_rate: {48_000, 1},
      capabilities: %{
        encodings: [:s16le],
        max_frame_samples: 960,
        max_payload_bytes: 1920,
        replay: :durable_spool,
        commands: []
      }
    }

    spec = %{spec | descriptor_ref: MedEx.Serialization.descriptor_ref(spec)}

    frame = %SampleFrame{
      stream_id: "s",
      source_epoch: 3,
      descriptor_ref: spec.descriptor_ref,
      sequence: 0,
      first_sample: 0,
      sample_count: 1,
      config_epoch: 0,
      payload: <<2, 3>>
    }

    %{frame: frame, opts: [stream: spec, artifact_dir: dir, fence: "f", owner: self()]}
  end

  test "invalid port receipt stops admission even though the append really occurred", c do
    {:ok, w} = StreamWriter.start_link(c.opts ++ [storage: InvalidReceipt])
    {:ok, _} = StreamWriter.push(w, c.frame)
    assert {:error, {:outcome_unknown, :invalid_storage_receipt}} = StreamWriter.checkpoint(w)

    assert {:ok, %{receipt: %{durable_sample: 1}, sealed: false}} =
             Store.recover(c.tmp_dir, c.opts)
  end

  test "definite immutable target conflict does not acknowledge coverage", c do
    {:ok, w} = StreamWriter.start_link(c.opts)
    {:ok, _} = StreamWriter.push(w, c.frame)
    hash = MedEx.Serialization.sha256(c.frame.payload)
    File.write!(Path.join(c.tmp_dir, hash <> ".pcm"), <<3, 4>>)
    assert {:error, {:not_committed, :object_digest}} = StreamWriter.checkpoint(w)
    assert {:ok, %{durable_sample: 0}} = StreamWriter.receipt(w)
    File.rm!(Path.join(c.tmp_dir, hash <> ".pcm"))
    assert {:ok, _} = StreamWriter.finish(w)
  end

  test "caller timeout leaves the writer occupied until its own commit completes", c do
    parent = self()
    entered = :atomics.new(1, [])

    hook = fn
      :before_object_sync ->
        if :atomics.add_get(entered, 1, 1) == 1 do
          send(parent, {:blocked, self()})

          receive do
            :resume -> :ok
          end
        else
          :ok
        end

      _ ->
        :ok
    end

    {:ok, w} = StreamWriter.start_link(c.opts ++ [fault_hook: hook])
    {:ok, _} = StreamWriter.push(w, c.frame)
    assert {:error, {:outcome_unknown, :timeout}} = StreamWriter.checkpoint(w, 5)
    assert_receive {:blocked, ^w}
    assert {:error, :writer_active} = Store.recover(c.tmp_dir, c.opts)
    send(w, :resume)
    assert {:ok, r} = StreamWriter.receipt(w)
    assert r.durable_sample == 1
    assert {:ok, _} = StreamWriter.finish(w)
  end

  test "owner death records interruption while a surviving host can recover the terminal", c do
    parent = self()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        {:ok, w} = StreamWriter.start_link(Keyword.put(c.opts, :owner, self()))
        {:ok, _} = StreamWriter.push(w, c.frame)
        send(parent, {:owner_writer, w})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:owner_writer, w}
    ref = Process.monitor(w)
    send(owner, :done)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:DOWN, ^ref, :process, ^w, :normal}, 1_000

    assert {:ok,
            %{index: %{terminal: :interrupted, terminal_reason: "owner_lost", next_sample: 1}}} =
             Store.recover(c.tmp_dir, c.opts)
  end
end
