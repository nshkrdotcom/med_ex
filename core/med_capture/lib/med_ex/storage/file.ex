defmodule MedEx.Storage.File do
  @moduledoc """
  POSIX single-writer adapter. A host grants each attempt a distinct, trusted
  local directory. Reconciliation requires prior fencing and confirmed quiescence.
  Chunks and snapshots are installed exclusively and synced before journal ACKs.
  """
  @behaviour MedEx.Storage
  alias MedEx.{
    CanonicalJSON,
    ContractRules,
    Receipt,
    RecordingLimits,
    SegmentRef,
    Serialization,
    StreamIndex,
    StreamSpec
  }

  alias MedEx.Storage.{
    EffectiveUID,
    Journal,
    Objects,
    Records,
    RecoveredPrefix,
    Terminal,
    Transfer,
    Usage,
    VerifiedIndex
  }

  @journal "stream.mejournal"
  @max_predecessors RecordingLimits.maximum().predecessor_depth

  @impl true
  def open(opts) do
    dir = Keyword.fetch!(opts, :artifact_dir)

    case root_ownership(dir, opts[:root_owner]) do
      {:ok, ownership} -> open_owned(dir, Keyword.put(opts, :ownership, ownership))
      {:error, reason} -> {:error, {:not_committed, reason}}
    end
  end

  defp open_owned(dir, opts) do
    if acquire(dir) do
      open_acquired(dir, opts)
    else
      {:error, {:not_committed, :writer_active}}
    end
  end

  defp open_acquired(dir, opts) do
    case open_locked(opts) do
      {:ok, handle, receipt} ->
        %Transfer{handle: handle, result: {:ok, receipt}}

      error ->
        release(dir)
        error
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
    hook = Keyword.get(opts, :_fault_hook, fn _ -> :ok end)

    with :ok <- StreamSpec.validate(spec),
         true <- ContractRules.id?(fence),
         :ok <- create_dir(dir),
         {:ok, old, imported} <-
           prepare_import(dir, spec, fence, opts[:predecessor], opts[:limits]),
         header =
           Serialization.to_map(%{
             type: "identity",
             schema: "medex.journal.v2",
             stream: spec,
             fence: fence,
             journal_id: Objects.nonce(),
             predecessor: imported
           }),
         {:ok, fd} <- :file.open(Path.join(dir, @journal), [:raw, :binary, :write, :exclusive]) do
      s = %{
        dir: dir,
        fd: fd,
        hook: hook,
        view: reset(old, fence, header),
        offset: 0,
        ownership: opts[:ownership],
        retired: :atomics.new(1, []),
        limits: opts[:limits]
      }

      append_identity(s, header)
    else
      false -> {:error, {:not_committed, :invalid_fence}}
      {:ok, _} -> {:error, {:not_committed, :invalid_directory}}
      {:error, reason} -> {:error, {:not_committed, reason}}
    end
  end

  defp append_identity(s, header) do
    result =
      try do
        with {:ok, next, receipt} <- append(s, header, s.view),
             :ok <- Objects.sync_directory(s.dir),
             do: {:ok, next, receipt}
      rescue
        _ -> {:error, {:outcome_unknown, :storage_exception}}
      catch
        _, _ -> {:error, {:outcome_unknown, :storage_exception}}
      end

    case result do
      {:ok, _, _} ->
        result

      _ ->
        close(s)
        result
    end
  end

  defp create_dir(dir) do
    with :ok <- ensure_dir(dir),
         {:ok, %{type: :directory}} <- File.lstat(dir),
         do: Objects.sync_directory(Path.dirname(dir))
  end

  defp ensure_dir(dir) do
    case File.mkdir(dir) do
      :ok ->
        File.chmod(dir, 0o700)

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

  defp prepare_import(_dir, spec, fence, nil, _limits),
    do: {:ok, Records.initial(spec, fence), nil}

  defp prepare_import(
         dir,
         spec,
         fence,
         %RecoveredPrefix{artifact_dir: old, receipt: expected, provenance: provenance},
         limits
       ) do
    if Path.expand(dir) == Path.expand(old) or provenance[:scope] != :full_journal or
         not Receipt.exact_prefix?(expected, provenance[:receipt]) or
         not is_map(provenance[:prefixes]) or
         map_size(provenance[:prefixes]) >= limits.predecessor_depth or
         root_ownership(old, provenance[:root_owner]) !=
           {:ok,
            %{
              root: provenance[:root],
              owner: provenance[:root_owner],
              token: provenance[:root_token]
            }} do
      {:error, :predecessor_mismatch}
    else
      with_quiescence(old, fn -> copy_import(dir, spec, fence, old, expected) end)
    end
  end

  defp prepare_import(_, _, _, _, _), do: {:error, :invalid_predecessor}

  defp copy_import(dir, spec, fence, old, expected) do
    with {:ok, known} <- Receipt.parse(expected),
         true <- known.fence != fence and Path.expand(dir) != Path.expand(old),
         {:ok, view, size, _torn} <- read_journal(old, @journal, spec, known.fence, known, 0),
         true <- Receipt.exact_prefix?(known, Records.receipt(view)),
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
  def commit_batch(s, event) do
    case ensure_current(s) do
      :ok -> transfer_result(s, fn -> commit(s, event) end)
      {:error, reason} -> %Transfer{handle: s, result: {:error, {:outcome_unknown, reason}}}
    end
  end

  defp commit(s, {:frames, frames}) when is_list(frames) and length(frames) in 1..16 do
    {record, bytes, segment} = Records.chunk_record(frames)

    with {:ok, view} <- Records.apply_record(s.view, record, fn _ -> {:ok, bytes} end),
         :ok <- Objects.install(s.dir, segment.key, bytes, s.hook),
         do: append(s, record, view)
  end

  defp commit(s, {:gap, gap}) do
    record = Serialization.to_map(%{type: "gap", gap: gap})
    with {:ok, view} <- Records.apply_record(s.view, record, nil), do: append(s, record, view)
  end

  defp commit(_, _), do: {:error, {:not_committed, :invalid_batch}}

  defp transfer_result(s, operation) do
    case operation.() do
      %Transfer{} = transfer ->
        transfer

      {:ok, next, value} ->
        %Transfer{handle: next, result: {:ok, value}}

      {:error, {kind, _} = reason} when kind in [:not_committed, :outcome_unknown] ->
        %Transfer{handle: s, result: {:error, reason}}

      {:error, reason} ->
        %Transfer{handle: s, result: {:error, {:not_committed, reason}}}

      _ ->
        %Transfer{handle: s, result: {:error, {:outcome_unknown, :invalid_storage_result}}}
    end
  rescue
    _ -> %Transfer{handle: s, result: {:error, {:outcome_unknown, :storage_exception}}}
  catch
    _, _ -> %Transfer{handle: s, result: {:error, {:outcome_unknown, :storage_exception}}}
  end

  defp append(s, record, view) do
    gen = s.view.generation + 1
    {envelope, digest} = Journal.envelope(gen, s.view.digest, record)
    offset = s.offset + IO.iodata_length(envelope)

    with :ok <- ensure_current(s),
         true <- offset <= s.limits.journal_bytes and gen <= s.limits.generations,
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
    do: %Usage{
      raw_bytes: s.view.byte_total,
      frame_count: map_size(s.view.frames),
      span_count: s.view.span_count,
      journal_bytes: s.offset,
      journal_generation: s.view.generation
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
    if :atomics.compare_exchange(s.retired, 1, 0, 1) == :ok do
      try do
        :file.close(s.fd)
      after
        release(s.dir)
      end
    else
      :ok
    end
  end

  @impl true
  def seal(s, terminal, reason) do
    case ensure_current(s) do
      :ok -> transfer_result(s, fn -> seal_current(s, terminal, reason) end)
      {:error, reason} -> %Transfer{handle: s, result: {:error, {:outcome_unknown, reason}}}
    end
  end

  defp seal_current(s, terminal, reason) do
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
      opts = [
        stream: view.cursor.stream,
        fence: view.fence,
        known_receipt: receipt,
        root_owner: s.ownership.owner
      ]

      result =
        with {:ok, recovered} <- recover_locked(s.dir, opts),
             true <- recovered.index == Records.index(committed.view),
             :ok <- s.hook.(:before_index_install),
             :ok <- install_index(s.dir, recovered.index, s.hook),
             :ok <- s.hook.(:after_index_install),
             {:ok, verified} <- recover_locked(s.dir, opts),
             {:ok, final} <-
               Receipt.terminal_receipt(verified.index, verified, Records.receipt(s.view)) do
          {:ok, %Terminal{index: verified.index, receipt: final, recovered: verified}}
        else
          _ -> {:error, {:outcome_unknown, :unverified_terminal}}
        end

      # Adoption of the updated handle is independent of terminal validation.
      case result do
        {:ok, terminal_result} -> {:ok, committed, terminal_result}
        error -> %Transfer{handle: committed, result: error}
      end
    end
  end

  @doc "Install only the exact immutable index of a quiescent, verified terminal journal."
  def reconcile_terminal(dir, opts), do: recovery_call(dir, opts, &reconcile_locked/2)

  defp reconcile_locked(dir, opts) do
    with {:ok, result} <- recover_locked(dir, opts),
         true <- result.terminal_recorded,
         {:ok, _} <- root_ownership(dir, opts[:root_owner]),
         :ok <- install_index(dir, result.index, fn _ -> :ok end),
         {:ok, verified} <- recover_locked(dir, opts),
         true <- verified.index_status == :installed do
      {:ok, verified}
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
  def recover(dir, opts), do: recovery_call(dir, opts, &recover_locked/2)

  defp recovery_call(dir, opts, operation) when is_binary(dir) and is_list(opts) do
    if recovery_options?(opts) do
      hook =
        if Code.ensure_loaded?(ExUnit), do: Process.get({__MODULE__, :recovery_hook}), else: nil

      bounded(opts, fn -> recover_quiescent(dir, opts, operation, hook) end)
    else
      {:error, :invalid_recovery_options}
    end
  end

  defp recovery_call(_, _, _), do: {:error, :invalid_recovery_options}

  defp recovery_options?(opts) do
    Keyword.keyword?(opts) and recovery_keys?(opts) and
      is_integer(Keyword.get(opts, :timeout, 30_000)) and
      Keyword.get(opts, :timeout, 30_000) in 1..30_000 and required_recovery_keys?(opts)
  end

  defp recovery_keys?(opts) do
    keys = Keyword.keys(opts)

    Enum.all?(keys, &(&1 in [:stream, :fence, :root_owner, :known_receipt, :timeout])) and
      length(keys) == length(Enum.uniq(keys))
  end

  defp required_recovery_keys?(opts) do
    Keyword.has_key?(opts, :stream) and Keyword.has_key?(opts, :fence) and
      Keyword.has_key?(opts, :root_owner)
  end

  defp recover_quiescent(dir, opts, operation, hook) do
    with_quiescence(dir, fn ->
      if is_function(hook, 1), do: hook.(:quiescence_acquired)
      operation.(dir, opts)
    end)
  end

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

    with {:ok, ownership} <- root_ownership(dir, opts[:root_owner]),
         :ok <- StreamSpec.validate(stream),
         true <- ContractRules.id?(fence),
         :ok <- known_receipt(opts[:known_receipt]),
         {:ok, view, _, torn} <-
           read_journal(dir, @journal, stream, fence, opts[:known_receipt], 0),
         :ok <- sync_recovered(Path.join(dir, @journal)),
         :ok <- Objects.sync_directory(dir),
         index = Records.index(view),
         :ok <- StreamIndex.validate(index),
         {:ok, digest} <- installed_index(dir, view, index) do
      receipt = Records.receipt(view)

      {:ok,
       %RecoveredPrefix{
         artifact_dir: Path.expand(dir),
         stream: stream,
         fence: fence,
         cursor: view.cursor,
         index: index,
         receipt: receipt,
         index_digest: digest,
         torn_tail: torn,
         sealed: not is_nil(digest),
         terminal_recorded: not is_nil(view.terminal),
         index_status: if(is_nil(digest), do: :absent, else: :installed),
         provenance: %{
           scope: :full_journal,
           receipt: receipt,
           root: ownership.root,
           root_owner: ownership.owner,
           root_token: ownership.token,
           predecessor: view.predecessor,
           prefixes: view.prefixes,
           journal_bytes: byte_size_journal(dir)
         }
       }}
    else
      false -> {:error, :invalid_fence}
      error -> error
    end
  end

  defp known_receipt(nil), do: :ok

  defp known_receipt(receipt) do
    if Receipt.durable?(receipt), do: :ok, else: {:error, :not_durable_receipt}
  end

  defp byte_size_journal(dir), do: File.stat!(Path.join(dir, @journal)).size

  defp sync_recovered(path) do
    with {:ok, fd} <- :file.open(path, [:raw, :read]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp installed_index(dir, %{terminal: nil}, _) do
    with {:ok, names} <- File.ls(dir) do
      if Enum.any?(names, &String.ends_with?(&1, ".index.mej1")),
        do: {:error, :conflicting_index},
        else: {:ok, nil}
    end
  end

  defp installed_index(dir, _, index) do
    bytes = Serialization.bytes(index)
    hash = Serialization.sha256(bytes)

    with {:ok, names} <- File.ls(dir),
         true <-
           Enum.all?(names, fn name ->
             not String.ends_with?(name, ".index.mej1") or name == hash <> ".index.mej1"
           end) do
      case Objects.verify(Path.join(dir, hash <> ".index.mej1"), byte_size(bytes), hash) do
        :ok -> {:ok, hash}
        {:error, :enoent} -> {:ok, nil}
        error -> error
      end
    else
      false -> {:error, :conflicting_index}
      error -> error
    end
  end

  defp read_journal(dir, key, spec, fence, known, depth) do
    step = fn record, gen, digest, {view, seen} ->
      with {:ok, next} <- interpret(dir, spec, fence, record, gen, view, depth) do
        next = %{next | generation: gen, digest: digest}
        matches = seen or Receipt.exact_prefix?(known, Records.receipt(next))
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
           "schema" => "medex.journal.v2",
           "stream" => stored,
           "fence" => fence,
           "journal_id" => id,
           "predecessor" => prev
         } = header,
         1,
         nil,
         depth
       )
       when map_size(header) == 6 do
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
         true <- size >= 1 and size <= RecordingLimits.maximum().journal_bytes,
         {:ok, known} <- Receipt.parse(raw),
         true <- known.fence != fence,
         :ok <- Objects.verify(Path.join(dir, key), size, hex),
         {:ok, view, ^size, false} <- read_journal(dir, key, spec, known.fence, known, depth + 1),
         true <-
           Receipt.exact_prefix?(known, Records.receipt(view)) and
             view.terminal not in [:finished, :failed] do
      {:ok, %{view | prefixes: Map.put(view.prefixes, key, size)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_frozen_prefix}
    end
  end

  defp load_import(_, _, _, _, _), do: {:error, :invalid_predecessor}

  defp read_segment(dir, %SegmentRef{} = seg) do
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

  @doc "Load immutable index bytes once, bound to an authorized promoted manifest."
  def read_verified_index(dir, digest, expected) when is_map(expected) do
    with true <-
           ContractRules.digest?(digest) and expected[:index_digest] == digest and
             ContractRules.digest?(expected[:manifest_digest]),
         {:ok, ownership} <- root_ownership(dir, expected[:root_owner]),
         path = Path.join(dir, digest <> ".index.mej1"),
         {:ok, bytes, stamp} <- read_index_bytes(path),
         true <- Serialization.sha256(bytes) == digest,
         {:ok, map} <- CanonicalJSON.decode(bytes),
         {:ok, index} <- Serialization.stream_index(map),
         true <- Serialization.bytes(index) == bytes,
         :ok <- index_identity(index, expected) do
      {:ok,
       %VerifiedIndex{
         artifact_dir: Path.expand(dir),
         index: index,
         index_digest: digest,
         manifest_digest: expected.manifest_digest,
         segments: Map.new(index.segments, &{&1.first_sample, &1}),
         provenance: %{
           scope: :immutable_index,
           root: ownership.root,
           root_owner: ownership.owner,
           root_token: ownership.token,
           index_stamp: stamp
         }
       }}
    else
      false -> {:error, :unverified_index}
      error -> error
    end
  end

  def read_verified_index(_, _, _), do: {:error, :unverified_index}

  @doc "Read and verify exactly the requested indexed PCM bytes without replaying the journal."
  def read_verified_segment(%VerifiedIndex{} = verified, first_sample, expected)
      when is_integer(first_sample) and first_sample >= 0 and is_map(expected) do
    with true <-
           verified.index_digest == expected[:index_digest] and
             verified.manifest_digest == expected[:manifest_digest],
         :ok <- index_identity(verified.index, expected),
         {:ok, owner} <- root_ownership(verified.artifact_dir, expected[:root_owner]),
         true <-
           {owner.root, owner.owner, owner.token} ==
             {verified.provenance.root, verified.provenance.root_owner,
              verified.provenance.root_token},
         {:ok, stamp} <-
           index_stamp(Path.join(verified.artifact_dir, verified.index_digest <> ".index.mej1")),
         true <- stamp == verified.provenance.index_stamp,
         {:ok, segment} <- Map.fetch(verified.segments, first_sample),
         {:ok, bytes} <- read_segment(verified.artifact_dir, segment) do
      {:ok, bytes}
    else
      false -> {:error, :verification_provenance_changed}
      :error -> {:error, :segment_not_found}
      error -> error
    end
  end

  def read_verified_segment(_, _, _), do: {:error, :unverified_segment}

  defp index_identity(index, expected) do
    required = [:stream_id, :source_epoch, :descriptor_ref, :fence, :journal_id]

    actual = %{
      stream_id: index.stream.stream_id,
      source_epoch: index.stream.source_epoch,
      descriptor_ref: index.stream.descriptor_ref,
      fence: index.fence,
      journal_id: index.journal_id
    }

    if Enum.all?(required, &(Map.fetch(expected, &1) == Map.fetch(actual, &1))),
      do: :ok,
      else: {:error, :index_identity}
  end

  defp read_index_bytes(path) do
    with {:ok, stamp} <- index_stamp(path),
         {:ok, fd} <- :file.open(path, [:raw, :binary, :read]) do
      try do
        with {:ok, bytes} <- :file.read(fd, stamp.size + 1),
             true <- byte_size(bytes) == stamp.size,
             {:ok, ^stamp} <- index_stamp(path) do
          {:ok, bytes, stamp}
        else
          _ -> {:error, :invalid_index_file}
        end
      after
        :file.close(fd)
      end
    end
  end

  defp index_stamp(path) do
    with {:ok, %{type: :regular, size: size} = stat} <- File.lstat(path),
         true <- size > 0 and size <= RecordingLimits.maximum().journal_bytes do
      {:ok,
       Map.take(stat, [:size, :inode, :major_device, :minor_device, :mtime, :ctime, :uid, :mode])}
    else
      _ -> {:error, :invalid_index_file}
    end
  end

  defp ensure_current(s) do
    with true <- :atomics.get(s.retired, 1) == 0,
         {:ok, current} <- root_ownership(s.dir, s.ownership.owner),
         true <- current == s.ownership,
         true <- is_nil(s.view.terminal) do
      :ok
    else
      _ -> {:error, :ownership_lost_or_sealed}
    end
  end

  defp root_ownership(dir, owner) when is_binary(dir) and is_pid(owner) do
    with true <- node(owner) == node() and Process.alive?(owner),
         {:ok, %{root: root, token: token}} <-
           GenServer.call(owner, {:med_ex_root_ownership, Path.expand(dir)}, 1_000),
         true <- is_binary(root) and Path.type(root) == :absolute and is_reference(token),
         true <- within_root?(Path.expand(dir), Path.expand(root)),
         {:ok, uid} <- EffectiveUID.resolve(),
         :ok <- trusted_root(root, uid),
         :ok <- check_ancestors(Path.expand(dir), uid) do
      {:ok, %{root: Path.expand(root), owner: owner, token: token}}
    else
      _ -> {:error, :untrusted_root}
    end
  catch
    :exit, _ -> {:error, :root_owner_unavailable}
  end

  defp root_ownership(_, _), do: {:error, :root_owner_required}

  defp within_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp trusted_root(root, uid) do
    with {:ok, %{type: :directory, uid: ^uid, mode: mode}} <- File.lstat(root),
         true <- Bitwise.band(mode, 0o022) == 0 do
      :ok
    else
      _ -> {:error, :untrusted_root}
    end
  end

  defp check_ancestors(path, uid) do
    case File.lstat(path) do
      {:error, :enoent} ->
        check_ancestors(Path.dirname(path), uid)

      {:ok, %{type: :directory, uid: owner, mode: mode}} when owner == uid or owner == 0 ->
        # Sticky ancestors protect the owned next directory from replacement;
        # the granted root itself must pass the stricter trusted_root check.
        if Bitwise.band(mode, 0o022) == 0 or Bitwise.band(mode, 0o1000) != 0 do
          check_parent(path, uid)
        else
          {:error, :untrusted_root_permissions}
        end

      _ ->
        {:error, :untrusted_root_path}
    end
  end

  defp check_parent("/", _), do: :ok
  defp check_parent(path, uid), do: check_ancestors(Path.dirname(path), uid)
end
