defmodule MedEx.StorageENOSPCTest do
  use ExUnit.Case, async: false
  alias MedEx.CaptureFixture, as: F
  alias MedEx.{Receipt, StreamWriter}
  alias MedEx.Storage.File, as: Store
  @moduletag :enospc
  @moduletag timeout: 120_000
  @marker ".med-ex-enospc-fixture.json"

  setup do
    assert :os.type() == {:unix, :linux}
    mount = System.fetch_env!("MED_EX_ENOSPC_ROOT") |> Path.expand()
    assert Path.type(System.fetch_env!("MED_EX_ENOSPC_ROOT")) == :absolute
    assert {:ok, %{uid: uid}} = File.stat("/proc/self")
    assert {:ok, %{type: :directory, uid: ^uid, mode: mode}} = File.lstat(mount)
    assert Bitwise.band(mode, 0o022) == 0
    assert {:ok, %{type: :regular, uid: ^uid, size: size}} = File.lstat(Path.join(mount, @marker))
    assert size in 1..4096
    marker = File.read!(Path.join(mount, @marker)) |> JSON.decode!()
    assert Enum.sort(Map.keys(marker)) == Enum.sort(~w(schema mount source max_fill_bytes))
    assert marker["schema"] == "medex.enospc_fixture.v2" and marker["mount"] == mount

    assert is_integer(marker["max_fill_bytes"]) and
             marker["max_fill_bytes"] in 1_048_576..1_073_741_824

    assert is_binary(marker["source"]) and
             Regex.match?(~r/\A\/dev\/loop[0-9]+\z/, marker["source"])

    {json, 0} =
      System.cmd("findmnt", ["--json", "--target", mount, "--output", "FSTYPE,SOURCE,TARGET"],
        stderr_to_stdout: true
      )

    assert %{"filesystems" => [%{"fstype" => "ext4", "source" => source, "target" => ^mount}]} =
             JSON.decode!(json)

    assert source == marker["source"]

    {block_size, 0} =
      System.cmd("stat", ["--file-system", "--format=%S", mount], stderr_to_stdout: true)

    assert String.trim(block_size) == "4096"
    # A marker is not enough: require the exact dedicated loop mount and a clean
    # fixture inventory, so no ordinary service/shared filesystem can be filled.
    assert Enum.all?(File.ls!(mount), &(&1 in [@marker, "lost+found"]))
    case_root = Path.join(mount, "med-ex-case-#{System.unique_integer([:positive])}")
    {:ok, guard} = MedEx.TestRootOwner.start_link(case_root)
    Process.unlink(guard)

    fixture = %{
      root: case_root,
      root_owner: guard,
      dir: Path.join(case_root, "attempt"),
      spec: F.spec(),
      filler: Path.join(case_root, "filler"),
      fill_limit: marker["max_fill_bytes"]
    }

    on_exit(fn -> F.cleanup(fixture) end)
    fixture
  end

  test "real object ENOSPC returns no durable acceptance and recovery preserves the old prefix",
       f do
    {:ok, writer} = F.start(f)
    {:ok, before} = StreamWriter.receipt(writer, "f1", 1000)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    :ok = exhaust(f)
    assert {:error, {:not_committed, :enospc}} = StreamWriter.checkpoint(writer, "f1", 30_000)
    assert {:ok, observed} = StreamWriter.receipt(writer, "f1", 1000)
    assert Receipt.durable_prefix(observed) == before
    F.retire(writer)
    release_space(f)
    assert {:ok, %{receipt: ^before, terminal_recorded: false}} = F.recover(f)
  end

  test "real journal ENOSPC after object install retires and leaves no fictitious receipt", f do
    test = self()

    Process.put({StreamWriter, :fault_hook}, fn
      :after_object_install ->
        :ok = exhaust(f)
        send(test, :object_installed_and_volume_full)
        :ok

      _ ->
        :ok
    end)

    {:ok, writer} = F.start(f)
    {:ok, before} = StreamWriter.receipt(writer, "f1", 1000)
    # Sixteen frame metadata records make this append larger than a filesystem
    # block, so it cannot fit in the identity record's existing allocation.
    {record, _, _} = MedEx.Storage.Records.chunk_record(Enum.map(0..15, &F.frame/1))
    assert MedEx.RecordingLimits.encoded_record_bytes(record) > 4096

    for sequence <- 0..14,
        do: assert({:ok, _} = StreamWriter.push(writer, "f1", F.frame(sequence), 1000))

    monitor = Process.monitor(writer)
    assert {:error, {:outcome_unknown, _}} = StreamWriter.push(writer, "f1", F.frame(15), 30_000)
    assert_receive :object_installed_and_volume_full
    assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}, 2000
    release_space(f)

    assert {:ok, %{receipt: ^before, terminal_recorded: false}} =
             F.recover(f, known_receipt: before)

    assert Enum.any?(File.ls!(f.dir), &String.ends_with?(&1, ".pcm"))
  end

  test "real index ENOSPC retains terminal journal truth and explicit reconciliation installs once",
       f do
    test = self()

    Process.put({StreamWriter, :fault_hook}, fn
      :before_index_install ->
        :ok = exhaust(f)
        send(test, :terminal_committed_and_volume_full)
        :ok

      _ ->
        :ok
    end)

    {:ok, writer} = F.start(f)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    {:ok, before} = StreamWriter.checkpoint(writer, "f1", 5000)
    monitor = Process.monitor(writer)
    assert {:error, {:outcome_unknown, _}} = StreamWriter.finish(writer, "f1", 30_000)
    assert_receive :terminal_committed_and_volume_full
    assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}, 2000
    release_space(f)
    assert {:ok, prefix} = F.recover(f, known_receipt: before)
    assert prefix.terminal_recorded and prefix.index_status == :absent and not prefix.sealed
    assert :ok = Receipt.committed_successor(before, prefix.receipt, prefix.cursor)
    opts = [stream: f.spec, fence: "f1", root_owner: f.root_owner]
    assert {:ok, sealed} = Store.reconcile_terminal(f.dir, opts)
    assert {:ok, ^sealed} = Store.reconcile_terminal(f.dir, opts)
    assert sealed.receipt == prefix.receipt and sealed.index_status == :installed
  end

  defp exhaust(f) do
    {:ok, fd} = :file.open(f.filler, [:raw, :binary, :write, :exclusive])

    try do
      block = :binary.copy(<<0>>, 1_048_576)
      fill(fd, block, f.fill_limit)
    after
      :file.close(fd)
    end
  end

  defp fill(_, _, left) when left <= 0,
    do: flunk("selected fixture did not reach ENOSPC within its declared fill bound")

  defp fill(fd, block, left) do
    bytes = min(byte_size(block), left)

    case :file.write(fd, binary_part(block, 0, bytes)) do
      :ok ->
        fill(fd, block, left - bytes)

      {:error, :enospc} ->
        # A large failed write can leave a small free tail; exhaust it too.
        finish_fill(fd, :binary.copy(<<0>>, 4096), 256)

      other ->
        flunk("fixture fill did not produce ENOSPC: #{inspect(other)}")
    end
  end

  defp finish_fill(_, _, 0), do: flunk("fixture retained unexpected free blocks after ENOSPC")

  defp finish_fill(fd, block, left) do
    case :file.write(fd, block) do
      :ok ->
        finish_fill(fd, block, left - 1)

      {:error, :enospc} ->
        assert :file.sync(fd) in [:ok, {:error, :enospc}]
        :ok

      other ->
        flunk("fixture final fill failed: #{inspect(other)}")
    end
  end

  defp release_space(f) do
    File.rm!(f.filler)
    :ok = MedEx.Storage.Objects.sync_directory(f.root)
  end
end
