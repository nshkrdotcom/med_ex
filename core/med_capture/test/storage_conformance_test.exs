defmodule MedEx.StorageConformanceTest do
  use ExUnit.Case, async: true
  alias MedEx.CaptureFixture, as: F
  alias MedEx.{Serialization, StreamWriter}
  alias MedEx.Storage.File, as: Store
  alias MedEx.Storage.{Journal, Records}

  setup do
    fixture = F.root()
    on_exit(fn -> F.cleanup(fixture) end)
    fixture
  end

  defp sealed(fixture) do
    {:ok, writer} = F.start(fixture)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    {:ok, terminal} = StreamWriter.finish(writer, "f1", 5000)
    terminal.recovered
  end

  test "frozen revision-2 journal, index and PCM verify by their original exact bytes", f do
    source = Path.join(__DIR__, "fixtures/revision2")
    manifest = File.read!(Path.join(source, "fixture.mej1")) |> JSON.decode!()

    for {name, digest} <- manifest["files"] do
      assert Serialization.sha256(File.read!(Path.join(source, name))) == digest
    end

    File.mkdir_p!(f.dir)
    File.chmod!(f.dir, 0o700)
    for name <- File.ls!(source), do: File.cp!(Path.join(source, name), Path.join(f.dir, name))

    {:ok, spec} =
      source
      |> Path.join("descriptor.mej1")
      |> File.read!()
      |> JSON.decode!()
      |> Serialization.stream_spec()

    {:ok, receipt} =
      source
      |> Path.join("receipt.mej1")
      |> File.read!()
      |> JSON.decode!()
      |> MedEx.Receipt.parse()

    assert {:ok, recovered} =
             Store.recover(f.dir,
               stream: spec,
               fence: "frozen-fence",
               root_owner: f.root_owner,
               known_receipt: receipt
             )

    assert recovered.index_digest == manifest["index_digest"]
    assert recovered.receipt == receipt and recovered.index.schema_version == 2
    assert {:ok, ^receipt} = MedEx.Receipt.terminal_receipt(recovered.index, recovered, receipt)

    assert {:error, :unverified_terminal} =
             MedEx.Receipt.terminal_receipt(
               %{recovered.index | next_sample: 961},
               recovered,
               receipt
             )

    assert {:ok, index} = F.verified(recovered)
    assert {:ok, pcm} = Store.read_verified_segment(index, 0, F.expected(recovered))
    assert byte_size(pcm) == 1920 and Serialization.sha256(pcm) == manifest["pcm_sha256"]
    # Same envelope bytes do not imply compatibility with retired content schema.
    old = %{
      type: "identity",
      schema: "medex.journal.v1",
      stream: spec,
      fence: "frozen-fence",
      journal_id: "frozen-journal",
      predecessor: nil
    }

    {envelope, _} = Journal.envelope(1, Journal.zero(), old)
    File.write!(Path.join(f.dir, "stream.mejournal"), envelope)

    assert {:error, :identity_mismatch} =
             Store.recover(f.dir, stream: spec, fence: "frozen-fence", root_owner: f.root_owner)
  end

  test "read-only recovery reports absent terminal index and explicit reconciliation installs once",
       f do
    prefix = sealed(f)
    index_path = Path.join(f.dir, prefix.index_digest <> ".index.mej1")
    bytes = File.read!(index_path)
    File.rm!(index_path)
    journal_path = Path.join(f.dir, "stream.mejournal")
    journal = File.read!(journal_path)
    assert {:ok, %{terminal_recorded: true, index_status: :absent, sealed: false}} = F.recover(f)
    refute File.exists?(index_path)
    assert File.read!(journal_path) == journal
    opts = [stream: f.spec, fence: "f1", root_owner: f.root_owner]
    assert {:ok, installed} = Store.reconcile_terminal(f.dir, opts)
    assert File.read!(index_path) == bytes
    assert {:ok, ^installed} = Store.reconcile_terminal(f.dir, opts)
    assert File.read!(journal_path) == journal
  end

  test "conflicting or corrupt immutable index is refused without overwrite", f do
    prefix = sealed(f)
    path = Path.join(f.dir, prefix.index_digest <> ".index.mej1")
    File.write!(path, "bad")
    assert {:error, _} = F.recover(f)

    assert {:error, _} =
             Store.reconcile_terminal(f.dir,
               stream: f.spec,
               fence: "f1",
               root_owner: f.root_owner
             )

    assert File.read!(path) == "bad"
  end

  test "orphan object is not evidence and partial tail is distinct from corrupt chain", f do
    {:ok, writer} = F.start(f)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    {:ok, receipt} = StreamWriter.checkpoint(writer, "f1", 1000)
    F.retire(writer)
    bytes = <<1, 2, 3, 4>>
    File.write!(Path.join(f.dir, Serialization.sha256(bytes) <> ".pcm"), bytes)
    path = Path.join(f.dir, "stream.mejournal")
    original = File.read!(path)
    File.write!(path, "ME", [:append])
    assert {:ok, %{torn_tail: true, receipt: ^receipt}} = F.recover(f, known_receipt: receipt)
    assert File.read!(path) == original <> "ME"
    File.write!(path, original <> <<255, 254>>)
    assert {:error, :journal_magic} = F.recover(f)
    <<head::binary-size(50), byte, rest::binary>> = original
    File.write!(path, <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)
    assert {:error, :journal_chain} = F.recover(f)
  end

  test "verified bounded segment reads reject tamper, wrong binding, symlinks and index replacement",
       f do
    prefix = sealed(f)
    {:ok, index} = F.verified(prefix)
    expected = F.expected(prefix)
    assert {:ok, bytes} = Store.read_verified_segment(index, 0, expected)
    assert bytes == F.frame(0).payload

    assert {:error, _} =
             Store.read_verified_segment(index, 0, %{
               expected
               | manifest_digest: String.duplicate("f", 64)
             })

    assert {:error, :segment_not_found} = Store.read_verified_segment(index, 1, expected)
    [segment] = prefix.index.segments
    path = Path.join(f.dir, segment.key)
    File.write!(path, :binary.copy(<<1>>, segment.byte_size))
    assert {:error, :invalid_object} = Store.read_verified_segment(index, 0, expected)
    File.rm!(path)
    outside = Path.join(f.root, "untrusted")
    File.write!(outside, bytes)
    File.ln_s!(outside, path)
    assert {:error, :invalid_object} = Store.read_verified_segment(index, 0, expected)
    File.rm!(path)
    File.write!(path, bytes)
    index_path = Path.join(f.dir, prefix.index_digest <> ".index.mej1")
    # Retain the original inode so the replacement cannot coincidentally reuse
    # it. Identical content is insufficient for reusing old file provenance.
    File.rename!(index_path, index_path <> ".old")
    File.cp!(index_path <> ".old", index_path)

    assert {:error, :verification_provenance_changed} =
             Store.read_verified_segment(index, 0, expected)

    assert {:ok, renewed} = F.verified(prefix)
    assert {:ok, ^bytes} = Store.read_verified_segment(renewed, 0, expected)
    GenServer.stop(f.root_owner)
    assert {:error, _} = Store.read_verified_segment(renewed, 0, expected)
  end

  test "logical budgets retain exact prefix at N-1/N/N+1 and reserve terminal bytes", f do
    for n <- [1, 2, 3] do
      local = %{f | dir: Path.join(f.root, "budget-#{n}")}
      {:ok, writer} = F.start(local, limits: %{frames: n, checkpoint_ms: :manual})

      for sequence <- 0..(n - 1),
          do: assert({:ok, _} = StreamWriter.push(writer, "f1", F.frame(sequence), 1000))

      assert {:error, {:not_committed, {:capacity, :frame_limit}}} =
               StreamWriter.push(writer, "f1", F.frame(n), 1000)

      assert {:ok, terminal} = StreamWriter.interrupt(writer, "f1", "capacity", 5000)
      assert terminal.receipt.durable_sequence == n
      assert terminal.index.terminal == :interrupted
    end
  end

  test "N bounded segment reads reuse immutable index provenance without N journal scans", f do
    {:ok, writer} = F.start(f)

    for sequence <- 0..7 do
      assert {:ok, _} = StreamWriter.push(writer, "f1", F.frame(sequence), 1000)
      assert {:ok, _} = StreamWriter.checkpoint(writer, "f1", 1000)
    end

    {:ok, terminal} = StreamWriter.finish(writer, "f1", 5000)
    {:ok, index} = F.verified(terminal.recovered)
    expected = F.expected(terminal.recovered)
    # Removing only the journal makes any per-read full-acquisition scan fail;
    # established index+segment scope remains sufficient for bounded playback.
    File.rm!(Path.join(f.dir, "stream.mejournal"))

    for sequence <- 0..7 do
      assert {:ok, bytes} = Store.read_verified_segment(index, sequence * 960, expected)
      assert bytes == F.frame(sequence).payload
    end

    assert {:error, :enoent} = F.recover(f)
  end

  test "another OS root owner is denied and lost root ownership denies effects", f do
    assert {:error, :root_in_use} = MedEx.TestRootOwner.start(f.root)
    {:ok, writer} = F.start(f)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    GenServer.stop(f.root_owner)
    assert {:error, {:outcome_unknown, _}} = StreamWriter.checkpoint(writer, "f1", 1000)
  end

  test "recovery timeout retains the actual lock until its worker quiesces", f do
    {:ok, writer} = F.start(f)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    {:ok, durable} = StreamWriter.checkpoint(writer, "f1", 1000)
    F.retire(writer)
    {:ok, predecessor} = F.recover(f)
    test = self()

    Process.put({Store, :recovery_hook}, fn :quiescence_acquired ->
      send(test, {:worker_locked, self()})

      receive do
        :release -> :ok
      end
    end)

    assert {:error, {:outcome_unknown, :timeout}} = F.recover(f, timeout: 20)
    Process.delete({Store, :recovery_hook})
    assert_receive {:worker_locked, worker}
    monitor = Process.monitor(worker)
    assert {:error, :writer_active} = F.recover(f)

    assert {:error, :writer_active} =
             Store.reconcile_terminal(f.dir,
               stream: f.spec,
               fence: "f1",
               root_owner: f.root_owner
             )

    successor = %{f | dir: Path.join(f.root, "successor")}

    assert {:error, {:not_committed, :writer_active}} =
             F.start(successor, fence: "f2", predecessor: predecessor)

    send(worker, :release)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2000
    assert {:ok, %{receipt: ^durable}} = F.recover(f)
    assert {:ok, next} = F.start(successor, fence: "f2", predecessor: predecessor)
    F.retire(next)
  end

  test "encoded journal byte and generation boundaries reserve an exact terminal commit", f do
    reference = %{f | dir: Path.join(f.root, "reference")}
    {:ok, writer} = F.start(reference)
    {:ok, %{journal_bytes: initial_bytes}} = StreamWriter.stats(writer, "f1", 1000)
    F.retire(writer)
    {record, _, _} = Records.chunk_record([F.frame(0)])

    exact =
      initial_bytes + MedEx.RecordingLimits.encoded_record_bytes(record) +
        MedEx.RecordingLimits.terminal_reserve_bytes()

    for {delta, accepted?} <- [{-1, false}, {0, true}, {1, true}] do
      local = %{f | dir: Path.join(f.root, "journal-#{delta}")}

      {:ok, limited} =
        F.start(local,
          limits: %{journal_bytes: exact + delta, generations: 3, checkpoint_ms: :manual}
        )

      result = StreamWriter.push(limited, "f1", F.frame(0), 1000)

      if accepted? do
        assert {:ok, _} = result
        assert {:ok, committed} = StreamWriter.checkpoint(limited, "f1", 1000)
        assert committed.journal_generation == 2

        assert {:error, {:not_committed, {:capacity, :journal_limit}}} =
                 StreamWriter.push(limited, "f1", F.frame(1), 1000)

        assert {:ok, terminal} = StreamWriter.finish(limited, "f1", 5000)
        assert terminal.receipt.journal_generation == 3
        assert {:ok, %{receipt: receipt}} = F.recover(local)
        assert receipt == terminal.receipt
      else
        assert {:error, {:not_committed, {:capacity, :journal_limit}}} = result
        assert {:ok, terminal} = StreamWriter.interrupt(limited, "f1", "capacity", 5000)
        assert terminal.receipt.durable_sequence == 0
      end
    end
  end

  test "service-owned root below a sticky temporary ancestor is supported", _f do
    root = Path.join(System.tmp_dir!(), "med-ex-root-#{System.unique_integer([:positive])}")
    {:ok, guard} = MedEx.TestRootOwner.start(root)
    fixture = %{root: root, root_owner: guard, dir: Path.join(root, "attempt"), spec: F.spec()}
    on_exit(fn -> F.cleanup(fixture) end)
    {:ok, writer} = F.start(fixture)
    assert {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    assert {:ok, terminal} = StreamWriter.finish(writer, "f1", 5000)
    assert {:ok, %{receipt: receipt}} = F.recover(fixture)
    assert terminal.receipt == receipt
  end
end
