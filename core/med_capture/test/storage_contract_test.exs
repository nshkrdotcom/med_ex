defmodule MedEx.StateTransferFault do
  @moduledoc false
  @behaviour MedEx.Storage
  alias MedEx.Storage.{File, Transfer}

  def open(opts) do
    {mode, test} = opts[:_fault_hook].(:fault_mode)

    case File.open(Keyword.delete(opts, :_fault_hook)) do
      %Transfer{handle: handle, result: {:ok, receipt}} ->
        wrapped = allocate(%{file: handle, mode: mode, test: test, count: 0})

        case mode do
          :open_bad ->
            %Transfer{handle: wrapped, result: {:ok, %{receipt | journal_digest: "bad"}}}

          :open_malformed ->
            close(wrapped)
            :unrecognized_open

          :open_throw ->
            close(wrapped)
            raise "controlled pre-transfer exception"

          _ ->
            %Transfer{handle: wrapped, result: {:ok, receipt}}
        end

      other ->
        other
    end
  end

  def commit_batch(%{mode: :known_noncommit, count: 0} = s, _),
    do: %Transfer{handle: %{s | count: 1}, result: {:error, {:not_committed, :injected}}}

  def commit_batch(s, event) do
    case File.commit_batch(s.file, event) do
      %Transfer{handle: handle, result: {:ok, receipt}} ->
        retire_aux(s)
        next = allocate(%{s | file: handle, count: s.count + 1})

        case s.mode do
          :commit_bad ->
            %Transfer{
              handle: next,
              result: {:ok, %{receipt | journal_generation: receipt.journal_generation + 1}}
            }

          :commit_malformed ->
            close(next)
            :malformed_envelope

          :commit_throw ->
            close(next)
            raise "controlled unreturned resource"

          _ ->
            %Transfer{handle: next, result: {:ok, receipt}}
        end

      %Transfer{handle: handle, result: result} ->
        %Transfer{handle: %{s | file: handle}, result: result}
    end
  end

  def usage(%{mode: :usage_bad}), do: %{raw_bytes: "bad"}
  def usage(%{mode: :usage_throw}), do: raise("controlled usage exception")
  def usage(s), do: File.usage(s.file)
  def lookup(%{mode: :lookup_bad}, _, _), do: {:ok, "not_a_digest"}
  def lookup(%{mode: :lookup_throw}, _, _), do: raise("controlled lookup exception")
  def lookup(s, kind, key), do: File.lookup(s.file, kind, key)

  def seal(s, terminal, reason) do
    case File.seal(s.file, terminal, reason) do
      %Transfer{handle: handle, result: {:ok, value}} ->
        retire_aux(s)
        next = allocate(%{s | file: handle})

        case s.mode do
          :seal_bad ->
            %Transfer{
              handle: next,
              result: {:ok, %{value | receipt: %{value.receipt | journal_digest: "bad"}}}
            }

          :seal_index ->
            %Transfer{
              handle: next,
              result:
                {:ok, %{value | index: %{value.index | next_sample: value.index.next_sample + 1}}}
            }

          :seal_throw ->
            close(next)
            raise "controlled post-seal exception"

          _ ->
            %Transfer{handle: next, result: {:ok, value}}
        end

      %Transfer{handle: handle, result: result} ->
        %Transfer{handle: %{s | file: handle}, result: result}
    end
  end

  def close(s) do
    retire_aux(s)
    result = File.close(s.file)

    case s.mode do
      :close_error -> {:error, :controlled_close_error}
      :close_throw -> raise "controlled close exception after actual resource release"
      _ -> result
    end
  end

  defp allocate(s) do
    token = make_ref()
    path = Path.join(s.file.dir, "fault-#{System.unique_integer([:positive])}")
    {:ok, fd} = :file.open(path, [:raw, :write, :exclusive])
    send(s.test, {:allocated, token})
    Map.merge(s, %{token: token, fd: fd, closed: :atomics.new(1, [])})
  end

  defp retire_aux(s) do
    if :atomics.compare_exchange(s.closed, 1, 0, 1) == :ok do
      :ok = :file.close(s.fd)
      send(s.test, {:closed, s.token})
    end

    :ok
  end
end

defmodule MedEx.StorageContractTest do
  use ExUnit.Case, async: true
  alias MedEx.CaptureFixture, as: F
  alias MedEx.{Receipt, StreamWriter}

  setup do
    fixture = F.root()
    on_exit(fn -> F.cleanup(fixture) end)
    fixture
  end

  defp seam(mode) do
    test = self()
    Process.put({StreamWriter, :test_storage}, MedEx.StateTransferFault)

    Process.put({StreamWriter, :fault_hook}, fn
      :fault_mode -> {mode, test}
      _ -> :ok
    end)
  end

  defp count_resources(allocated \\ [], closed \\ []) do
    receive do
      {:allocated, token} -> count_resources([token | allocated], closed)
      {:closed, token} -> count_resources(allocated, [token | closed])
    after
      0 -> {Enum.sort(allocated), Enum.sort(closed)}
    end
  end

  test "recognized state-replacing success adopts the new handle and closes each resource once",
       f do
    seam(:success)
    {:ok, writer} = F.start(f)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    assert {:ok, r} = StreamWriter.checkpoint(writer, "f1", 1000)
    assert Receipt.durable?(r)
    assert {:ok, _} = StreamWriter.finish(writer, "f1", 5000)
    {allocated, closed} = count_resources()
    assert length(allocated) == 3
    assert allocated == closed and length(Enum.uniq(closed)) == 3
  end

  test "malformed open transfers ownership before validation and thrown open cleans invisible resources",
       f do
    for mode <- [:open_bad, :open_malformed, :open_throw] do
      seam(mode)
      local = %{f | dir: Path.join(f.root, Atom.to_string(mode))}
      assert {:error, _} = F.start(local)
      {allocated, closed} = count_resources()
      assert length(allocated) == 1 and allocated == closed
      assert {:ok, _} = F.recover(local)
    end
  end

  test "bad receipt, malformed transfer and throw after replacing A with B retire exact resources",
       f do
    for mode <- [:commit_bad, :commit_malformed, :commit_throw] do
      seam(mode)
      local = %{f | dir: Path.join(f.root, Atom.to_string(mode))}
      {:ok, writer} = F.start(local)
      {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
      ref = Process.monitor(writer)
      assert {:error, {:outcome_unknown, _}} = StreamWriter.checkpoint(writer, "f1", 1000)
      assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
      {allocated, closed} = count_resources()
      assert length(allocated) == 2 and allocated == closed and length(Enum.uniq(closed)) == 2
      assert {:ok, %{receipt: %{durable_sample: 960}}} = F.recover(local)
    end
  end

  test "known noncommit returns usable ownership and permits a controlled exact retry", f do
    seam(:known_noncommit)
    {:ok, writer} = F.start(f)
    {:ok, initial} = StreamWriter.receipt(writer, "f1", 1000)
    {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
    assert {:error, {:not_committed, :injected}} = StreamWriter.checkpoint(writer, "f1", 1000)
    {:ok, observed} = StreamWriter.receipt(writer, "f1", 1000)
    assert Receipt.durable_prefix(observed) == initial
    assert {:ok, durable} = StreamWriter.checkpoint(writer, "f1", 1000)
    assert durable.durable_sample == 960
    assert {:ok, _} = StreamWriter.finish(writer, "f1", 5000)
    {allocated, closed} = count_resources()
    assert allocated == closed
  end

  test "malformed/throwing usage and lookup cannot acknowledge progress", f do
    for mode <- [:usage_bad, :usage_throw, :lookup_bad, :lookup_throw] do
      seam(mode)
      local = %{f | dir: Path.join(f.root, Atom.to_string(mode))}
      {:ok, writer} = F.start(local)
      ref = Process.monitor(writer)

      result =
        if mode in [:usage_bad, :usage_throw] do
          StreamWriter.push(writer, "f1", F.frame(0), 1000)
        else
          gap = %{id: "gap"}
          StreamWriter.record_gap(writer, "f1", gap, 1000)
        end

      assert {:error, {:outcome_unknown, _}} = result
      assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
      {allocated, closed} = count_resources()
      assert allocated == closed
      assert {:ok, %{receipt: %{durable_sample: 0}}} = F.recover(local)
    end
  end

  test "malformed or thrown seal validates installed truth only through recovery", f do
    for mode <- [:seal_bad, :seal_index, :seal_throw, :close_error, :close_throw] do
      seam(mode)
      local = %{f | dir: Path.join(f.root, Atom.to_string(mode))}
      {:ok, writer} = F.start(local)
      {:ok, _} = StreamWriter.push(writer, "f1", F.frame(0), 1000)
      ref = Process.monitor(writer)
      assert {:error, {:outcome_unknown, _}} = StreamWriter.finish(writer, "f1", 5000)
      assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
      {allocated, closed} = count_resources()
      assert allocated == closed and length(Enum.uniq(closed)) == length(closed)
      assert {:ok, %{sealed: true}} = F.recover(local)
    end
  end
end
