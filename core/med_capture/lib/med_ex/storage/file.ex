defmodule MedEx.Storage.File do
  @moduledoc """
  POSIX single-writer adapter. A host grants each attempt a distinct, trusted
  local directory. Reconciliation requires prior fencing and confirmed quiescence.
  Chunks and snapshots are installed exclusively and synced before journal ACKs.
  """
  @behaviour MedEx.Storage
  alias MedEx.{ContractRules, SegmentRef, Serialization, StreamIndex, StreamSpec, Wav}
  alias MedEx.Storage.{Journal, Objects, Records}
  @journal "stream.mejournal"
  @max_predecessors 32

  @impl true
  def open(opts) do
    dir = Keyword.fetch!(opts, :artifact_dir)

    if acquire(dir) do
      case open_locked(opts) do
        {:ok, _, _} = success ->
          success

        error ->
          release(dir)
          error
      end
    else
      {:error, {:not_committed, :writer_active}}
    end
  end

  # This lock coordinates peers of this SDK on one BEAM only. Cross-VM
  # admission, process-death confirmation and fencing remain host obligations.
  defp acquire(dir), do: :global.set_lock({{__MODULE__, Path.expand(dir)}, self()}, [node()], 0)
  defp release(dir), do: :global.del_lock({{__MODULE__, Path.expand(dir)}, self()}, [node()])

  defp with_quiescence(dir, op) do
    if acquire(dir) do
      try do
        op.()
      after
        release(dir)
      end
    else
      {:error, :writer_active}
    end
  end

  defp open_locked(opts) do
    spec = Keyword.fetch!(opts, :stream)
    dir = Keyword.fetch!(opts, :artifact_dir)
    fence = Keyword.fetch!(opts, :fence)
    hook = Keyword.get(opts, :fault_hook, fn _ -> :ok end)

    with :ok <- StreamSpec.validate(spec),
         true <- ContractRules.id?(fence),
         :ok <- create_dir(dir),
         {:ok, old, imported} <- prepare_import(dir, spec, fence, opts[:predecessor]),
         header =
           Serialization.to_map(%{
             type: "identity",
             schema: "medex.journal.v1",
             stream: spec,
             fence: fence,
             journal_id: Objects.nonce(),
             predecessor: imported
           }),
         {:ok, fd} <- :file.open(Path.join(dir, @journal), [:raw, :binary, :write, :exclusive]) do
      s = %{dir: dir, fd: fd, hook: hook, view: reset(old, fence, header), offset: 0}

      case append(s, header, s.view) do
        {:ok, next, receipt} ->
          case Wav.sync_directory(dir) do
            :ok ->
              {:ok, next, receipt}

            {:error, reason} ->
              :file.close(fd)
              {:error, {:outcome_unknown, reason}}
          end

        error ->
          :file.close(fd)
          error
      end
    else
      false -> {:error, {:not_committed, :invalid_fence}}
      {:ok, _} -> {:error, {:not_committed, :invalid_directory}}
      {:error, reason} -> {:error, {:not_committed, reason}}
    end
  end

  defp create_dir(dir) do
    with :ok <- ensure_dir(dir),
         {:ok, %{type: :directory}} <- File.lstat(dir),
         do: Wav.sync_directory(Path.dirname(dir))
  end

  defp ensure_dir(dir) do
    case File.mkdir(dir) do
      :ok ->
        :ok

      {:error, :eexist} ->
        :ok

      {:error, :enoent} ->
        with :ok <- create_dir(Path.dirname(dir)), do: ensure_dir(dir)

      error ->
        error
    end
  end

  defp reset(view, fence, header) do
    %{
      view
      | fence: fence,
        journal_id: header["journal_id"],
        generation: 0,
        digest: Journal.zero(),
        terminal: nil,
        terminal_reason: nil,
        predecessor: header["predecessor"]
    }
  end

  defp prepare_import(_dir, spec, fence, nil), do: {:ok, Records.initial(spec, fence), nil}

  defp prepare_import(dir, spec, fence, %{artifact_dir: old, receipt: expected}) do
    if Path.expand(dir) == Path.expand(old) do
      {:error, :predecessor_mismatch}
    else
      with_quiescence(old, fn -> copy_import(dir, spec, fence, old, expected) end)
    end
  end

  defp prepare_import(_, _, _, _), do: {:error, :invalid_predecessor}

  defp copy_import(dir, spec, fence, old, expected) do
    with {:ok, known} <- Serialization.receipt(Serialization.to_map(expected)),
         true <- known.fence != fence and Path.expand(dir) != Path.expand(old),
         {:ok, view, size, _torn} <- read_journal(old, @journal, spec, known.fence, known, 0),
         true <- Records.durable_match?(Records.receipt(view), known),
         true <-
           view.terminal not in [:finished, :failed] and
             map_size(view.prefixes) < @max_predecessors,
         :ok <- duplicate_objects(view, old, dir),
         {:ok, key} <- Objects.copy_prefix(Path.join(old, @journal), dir, size),
         imported = %{
           "prefix" => key,
           "size" => Integer.to_string(size),
           "receipt" => Serialization.to_map(Records.receipt(view))
         },
         {:ok, copy} <- load_import(dir, spec, fence, imported, 0) do
      {:ok, copy, imported}
    else
      false -> {:error, :predecessor_mismatch}
      error -> error
    end
  end

  defp duplicate_objects(view, old, dir) do
    objects =
      Enum.map(view.segments, &{&1.key, &1.byte_size, &1.sha256}) ++
        Enum.map(view.prefixes, fn {key, size} -> {key, size, String.slice(key, 0, 64)} end)

    Enum.reduce_while(objects, :ok, fn {key, size, sha}, :ok ->
      case Objects.link(Path.join(old, key), Path.join(dir, key), size, sha) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @impl true
  def commit_batch(s, {:frames, frames}) when is_list(frames) and length(frames) in 1..16 do
    {record, bytes, segment} = Records.chunk_record(frames)

    with {:ok, view} <- Records.apply_record(s.view, record, fn _ -> {:ok, bytes} end),
         :ok <- Objects.install(s.dir, segment.key, bytes, s.hook) do
      append(s, record, view)
    else
      {:error, reason} -> {:error, {:not_committed, reason}}
    end
  end

  def commit_batch(s, {:gap, gap}) do
    record = Serialization.to_map(%{type: "gap", gap: gap})

    with {:ok, view} <- Records.apply_record(s.view, record, nil) do
      append(s, record, view)
    else
      {:error, reason} -> {:error, {:not_committed, reason}}
    end
  end

  defp append(s, record, view) do
    gen = s.view.generation + 1
    {envelope, digest} = Journal.envelope(gen, s.view.digest, record)
    offset = s.offset + IO.iodata_length(envelope)

    with true <- offset <= Journal.max_bytes(),
         :ok <- s.hook.(:before_journal_append) do
      with :ok <- :file.write(s.fd, envelope),
           :ok <- s.hook.(:after_journal_append),
           :ok <- :file.sync(s.fd),
           :ok <- s.hook.(:after_journal_sync) do
        view = %{view | generation: gen, digest: digest}
        {:ok, %{s | view: view, offset: offset}, Records.receipt(view)}
      else
        {:error, reason} -> {:error, {:outcome_unknown, reason}}
      end
    else
      false -> {:error, {:not_committed, :journal_limit}}
      {:error, reason} -> {:error, {:not_committed, reason}}
    end
  catch
    {:invalid, reason} -> {:error, {:not_committed, reason}}
  end

  @impl true
  def usage(s),
    do: %{
      raw_bytes: s.view.byte_total,
      frame_count: map_size(s.view.frames),
      span_count: s.view.span_count,
      journal_bytes: s.offset
    }

  @impl true
  def lookup(s, family, key) do
    index = if family == :frame, do: s.view.frames, else: s.view.gap_ids

    case Map.fetch(index, key) do
      :error -> :missing
      found -> found
    end
  end

  @impl true
  def close(s) do
    try do
      :file.close(s.fd)
    after
      release(s.dir)
    end
  end

  @impl true
  def seal(s, terminal, reason) do
    record =
      case {terminal, reason} do
        {:failed, %{conflict: facts}} ->
          %{type: "terminal", status: :failed, reason: "duplicate_conflict", conflict: facts}

        _ ->
          %{type: "terminal", status: terminal, reason: reason}
      end
      |> Serialization.to_map()

    with {:ok, view} <- Records.apply_record(s.view, record, nil),
         {:ok, committed, receipt} <- append(s, record, view) do
      # Verify durable bytes through the same decoder used after a crash.
      opts = [stream: view.cursor.stream, fence: view.fence, known_receipt: receipt]

      with {:ok, result} <- recover_locked(s.dir, opts),
           true <- result.index == Records.index(committed.view),
           :ok <- s.hook.(:before_index_install),
           :ok <- install_index(s.dir, result.index, s.hook),
           :ok <- s.hook.(:after_index_install) do
        {:ok, result.index}
      else
        false -> {:error, {:outcome_unknown, :index_mismatch}}
        {:error, reason} -> {:error, {:outcome_unknown, reason}}
      end
    end
  end

  @doc "Finish installing an already journaled terminal index under an externally quiesced fence."
  def reconcile_index(dir, opts),
    do: bounded(opts, fn -> with_quiescence(dir, fn -> reconcile_locked(dir, opts) end) end)

  defp reconcile_locked(dir, opts) do
    with {:ok, result} <- recover_locked(dir, opts),
         true <- result.terminal_recorded,
         :ok <- install_index(dir, result.index, fn _ -> :ok end) do
      {:ok, %{result | index_digest: Serialization.digest(result.index), sealed: true}}
    else
      false -> {:error, :missing_terminal}
      error -> error
    end
  end

  defp install_index(dir, index, hook) do
    bytes = Serialization.bytes(index)
    Objects.install(dir, Serialization.sha256(bytes) <> ".index.mej1", bytes, hook)
  end

  @doc "Read a validated prefix and reconcile any previously acknowledged generation. Never truncates or appends."
  @impl true
  def recover(dir, opts),
    do: bounded(opts, fn -> with_quiescence(dir, fn -> recover_locked(dir, opts) end) end)

  defp bounded(opts, op) do
    # On deadline let a blocked OS operation finish under its original lock.
    # Discard the late result; timeout cannot establish cancellation.
    reply_to = :erlang.alias()
    token = make_ref()
    {worker, monitor} = spawn_monitor(fn -> send(reply_to, {token, op.()}) end)

    try do
      receive do
        {^token, result} -> result
        {:DOWN, ^monitor, :process, ^worker, reason} -> {:error, {:outcome_unknown, reason}}
      after
        Keyword.get(opts, :timeout, 30_000) -> {:error, {:outcome_unknown, :timeout}}
      end
    after
      :erlang.unalias(reply_to)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp recover_locked(dir, opts) do
    stream = Keyword.fetch!(opts, :stream)
    fence = Keyword.fetch!(opts, :fence)

    with :ok <- StreamSpec.validate(stream),
         {:ok, view, _, torn} <-
           read_journal(dir, @journal, stream, fence, opts[:known_receipt], 0),
         :ok <- sync_recovered(Path.join(dir, @journal)),
         :ok <- Wav.sync_directory(dir),
         index = Records.index(view),
         :ok <- StreamIndex.validate(index),
         {:ok, digest} <- installed_index(dir, view, index) do
      {:ok,
       %{
         index: index,
         receipt: Records.receipt(view),
         index_digest: digest,
         torn_tail: torn,
         sealed: not is_nil(digest),
         terminal_recorded: not is_nil(view.terminal)
       }}
    end
  end

  defp sync_recovered(path) do
    with {:ok, fd} <- :file.open(path, [:raw, :read]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp installed_index(_, %{terminal: nil}, _), do: {:ok, nil}

  defp installed_index(dir, _, index) do
    bytes = Serialization.bytes(index)
    hash = Serialization.sha256(bytes)

    case Objects.verify(Path.join(dir, hash <> ".index.mej1"), byte_size(bytes), hash) do
      :ok -> {:ok, hash}
      {:error, :enoent} -> {:ok, nil}
      error -> error
    end
  end

  defp read_journal(dir, key, spec, fence, known, depth) do
    step = fn record, gen, digest, {view, seen} ->
      with {:ok, next} <- interpret(dir, spec, fence, record, gen, view, depth) do
        next = %{next | generation: gen, digest: digest}
        matches = seen or Records.durable_match?(Records.receipt(next), known)
        {:ok, {next, matches}}
      end
    end

    case Journal.fold(Path.join(dir, key), {nil, is_nil(known)}, step) do
      {:ok, {nil, _}, _, _} -> {:error, :missing_identity}
      {:ok, {_, false}, _, _} -> {:error, :unverified_receipt}
      {:ok, {s, true}, size, torn} -> {:ok, s, size, torn}
      error -> error
    end
  rescue
    _ in [
      ArgumentError,
      FunctionClauseError,
      KeyError,
      Protocol.UndefinedError,
      BadMapError,
      ArithmeticError
    ] ->
      {:error, :invalid_journal_record}
  end

  defp interpret(
         dir,
         spec,
         fence,
         %{
           "type" => "identity",
           "schema" => "medex.journal.v1",
           "stream" => stored,
           "fence" => fence,
           "journal_id" => id,
           "predecessor" => prev
         } = header,
         1,
         nil,
         depth
       ) do
    with true <- ContractRules.id?(id) and stored == Serialization.to_map(spec),
         {:ok, old} <- load_import(dir, spec, fence, prev, depth) do
      {:ok, reset(old, fence, header)}
    else
      false -> {:error, :identity_mismatch}
      error -> error
    end
  end

  defp interpret(dir, _, _, record, gen, view, _) when gen > 1 and not is_nil(view),
    do: Records.apply_record(view, record, &read_segment(dir, &1))

  defp interpret(_, _, _, _, _, _, _), do: {:error, :identity_mismatch}

  defp load_import(_, spec, fence, nil, _), do: {:ok, Records.initial(spec, fence)}

  defp load_import(dir, spec, fence, %{"prefix" => key, "size" => count, "receipt" => raw}, depth)
       when depth < @max_predecessors do
    with <<hex::binary-size(64), ".prefix">> <- key,
         true <- ContractRules.digest?(hex),
         size = Serialization.integer!(count),
         true <- size in 1..268_435_456,
         {:ok, known} <- Serialization.receipt(raw),
         true <- known.fence != fence,
         :ok <- Objects.verify(Path.join(dir, key), size, hex),
         {:ok, view, ^size, false} <- read_journal(dir, key, spec, known.fence, known, depth + 1),
         true <-
           Records.durable_match?(Records.receipt(view), known) and
             view.terminal not in [:finished, :failed] do
      {:ok, %{view | prefixes: Map.put(view.prefixes, key, size)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_frozen_prefix}
    end
  end

  defp load_import(_, _, _, _, _), do: {:error, :invalid_predecessor}

  @doc "Read only a bounded regular chunk whose exact length and SHA-256 match its technical index."
  def read_segment(dir, %SegmentRef{} = seg) do
    with :ok <- SegmentRef.validate(seg),
         true <- seg.key == seg.sha256 <> ".pcm",
         path = Path.join(dir, seg.key),
         {:ok, %{type: :regular, size: size}} when size == seg.byte_size <- File.lstat(path),
         {:ok, fd} <- :file.open(path, [:raw, :binary, :read]) do
      try do
        with {:ok, bytes} <- :file.read(fd, seg.byte_size + 1),
             true <-
               byte_size(bytes) == seg.byte_size and Serialization.sha256(bytes) == seg.sha256 do
          {:ok, bytes}
        else
          _ -> {:error, :invalid_object}
        end
      after
        :file.close(fd)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_object}
    end
  end
end
