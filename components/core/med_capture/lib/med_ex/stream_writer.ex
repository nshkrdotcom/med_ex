defmodule MedEx.StreamWriter do
  @moduledoc """
  One owner and explicit fence per stream attempt. Every operation has one fenced
  signature and an explicit positive timeout. Accepted receipts are volatile;
  only a fully durable receipt authorizes a host to persist a durable observation.
  The default limits use a 250 ms checkpoint; protected hosts select `:manual`.
  Owner loss never flushes source bytes. Timeout/unknown retires the writer and
  requires quiescent File recovery before a new attempt. Terminal results retain
  the installed index and verified receipt; sealed operations cannot mutate.
  """
  use GenServer, restart: :temporary

  alias MedEx.{
    ContractRules,
    FrameFingerprint,
    Receipt,
    RecordingLimits,
    Serialization,
    StreamCursor
  }

  alias MedEx.Storage.{File, Records, RecoveredPrefix, Terminal, Transfer, Usage}
  @options [:owner, :fence, :stream, :artifact_dir, :limits, :predecessor, :root_owner]
  @open_timeout 30_000

  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @options)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      # Private conformance seam; no production backend option or global selection.
      storage =
        if Code.ensure_loaded?(ExUnit),
          do: Process.get({__MODULE__, :test_storage}, File),
          else: File

      hook = if Code.ensure_loaded?(ExUnit), do: Process.get({__MODULE__, :fault_hook}), else: nil

      case GenServer.start_link(__MODULE__, {opts, storage, hook, self()}, timeout: @open_timeout) do
        {:error, {:shutdown, reason}} -> {:error, reason}
        result -> result
      end
    else
      {:error, :invalid_options}
    end
  end

  def start_link(_), do: {:error, :invalid_options}

  def push(pid, fence, frame, timeout), do: call(pid, fence, {:push, frame}, timeout)
  def record_gap(pid, fence, gap, timeout), do: call(pid, fence, {:gap, gap}, timeout)
  def checkpoint(pid, fence, timeout), do: call(pid, fence, :checkpoint, timeout)
  def finish(pid, fence, timeout), do: call(pid, fence, :finish, timeout)
  def interrupt(pid, fence, reason, timeout), do: call(pid, fence, {:interrupt, reason}, timeout)
  def receipt(pid, fence, timeout), do: call(pid, fence, :receipt, timeout)
  def stats(pid, fence, timeout), do: call(pid, fence, :stats, timeout)

  defp call(pid, fence, request, timeout)
       when is_pid(pid) and is_integer(timeout) and timeout > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout

    case authorize(pid, fence, timeout) do
      :ok ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0,
          do: submitted_call(pid, fence, request, deadline, remaining),
          else: {:error, {:not_committed, :expired}}

      {:error, _} = error ->
        error

      _ ->
        {:error, {:not_committed, :invalid_writer_authorization}}
    end
  end

  defp call(_, _, _, _), do: {:error, :invalid_call}

  defp authorize(pid, fence, timeout) do
    GenServer.call(pid, {fence, :authorize}, timeout)
  catch
    :exit, _ -> {:error, {:not_committed, :writer_authorization_unavailable}}
  end

  defp submitted_call(pid, fence, request, deadline, timeout) do
    GenServer.call(pid, {fence, request, deadline}, timeout)
  catch
    :exit, _ ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
      {:error, {:outcome_unknown, :writer_call_failed}}
  end

  @impl true
  def init({opts, storage, hook, caller}) do
    case initialize(opts, storage, hook) do
      {:stop, reason} ->
        Process.unlink(caller)
        {:stop, {:shutdown, reason}}

      success ->
        success
    end
  end

  defp initialize(opts, storage, hook) do
    owner = opts[:owner]
    stream = opts[:stream]
    fence = opts[:fence]

    with true <- local_owner?(owner),
         true <- ContractRules.id?(fence) and is_binary(opts[:artifact_dir]),
         {:ok, limits} <- RecordingLimits.new(opts[:limits] || %{}),
         {:ok, cursor} <- StreamCursor.new(stream),
         true <- stream.descriptor_ref == Serialization.descriptor_ref(stream),
         true <- predecessor?(opts[:predecessor]) do
      monitor = Process.monitor(owner)
      storage_opts = opts |> Keyword.put(:limits, limits)

      storage_opts =
        if is_function(hook, 1),
          do: Keyword.put(storage_opts, :_fault_hook, hook),
          else: storage_opts

      open_result = safely(fn -> storage.open(storage_opts) end)
      initialize_open(open_result, storage, opts, cursor, monitor, limits)
    else
      {:error, reason} -> {:stop, reason}
      false -> {:stop, :invalid_writer_options}
    end
  end

  defp local_owner?(owner), do: is_pid(owner) and node(owner) == node() and Process.alive?(owner)
  defp predecessor?(prefix), do: is_nil(prefix) or is_struct(prefix, RecoveredPrefix)

  defp initialize_open(
         %Transfer{handle: handle, result: {:ok, raw}},
         storage,
         opts,
         cursor,
         monitor,
         limits
       ) do
    owner = opts[:owner]
    stream = opts[:stream]
    fence = opts[:fence]

    with {:ok, r} <- Receipt.parse(raw),
         :ok <-
           Receipt.validate_identity(r, %{
             stream_id: stream.stream_id,
             source_epoch: stream.source_epoch,
             descriptor_ref: stream.descriptor_ref,
             fence: fence
           }),
         true <- Receipt.durable?(r),
         :ok <- initial_prefix(r, opts[:predecessor]),
         true <- Process.alive?(owner) do
      {:ok,
       %{
         owner: owner,
         monitor: monitor,
         fence: fence,
         cursor: %{
           cursor
           | next_sequence: r.durable_sequence,
             next_sample: r.durable_sample
         },
         limits: limits,
         storage: storage,
         adapter: handle,
         durable: r,
         pending: [],
         bytes: 0,
         count: 0,
         peak_count: 0,
         peak_bytes: 0,
         timer: nil,
         terminal: nil
       }}
    else
      _ ->
        safely(fn -> storage.close(handle) end)
        {:stop, :invalid_storage_open}
    end
  end

  defp initialize_open(%Transfer{handle: handle}, storage, _, _, _, _) do
    safely(fn -> storage.close(handle) end)
    {:stop, :invalid_storage_open}
  end

  defp initialize_open({:error, reason}, _, _, _, _, _), do: {:stop, reason}

  defp initialize_open(_, _, _, _, _, _), do: {:stop, {:outcome_unknown, :invalid_storage_open}}

  defp initial_prefix(r, nil) do
    if r.journal_generation == 1 and r.durable_sequence == 0 and r.durable_sample == 0,
      do: :ok,
      else: {:error, :invalid_initial_receipt}
  end

  defp initial_prefix(r, %RecoveredPrefix{} = prefix) do
    Receipt.handoff(prefix.receipt, r, %{
      previous: prefix.receipt,
      successor: r,
      authority: :verified_storage,
      authenticated: true,
      quiescent: true,
      imported: prefix
    })
  end

  @impl true
  def handle_call(_, {caller, _}, s) when caller != s.owner, do: {:reply, {:error, :not_owner}, s}

  def handle_call({fence, _, _}, _, s) when fence != s.fence,
    do: {:reply, {:error, :stale_fence}, s}

  def handle_call({fence, request, deadline}, from, s) do
    if is_integer(deadline) and System.monotonic_time(:millisecond) < deadline,
      do: handle_call({fence, request}, from, s),
      else: {:reply, {:error, {:not_committed, :expired}}, s}
  end

  def handle_call({fence, _}, _, s) when fence != s.fence, do: {:reply, {:error, :stale_fence}, s}
  def handle_call({_, :authorize}, _, s), do: {:reply, :ok, s}
  def handle_call({_, :receipt}, _, s), do: reply_receipt(s)

  def handle_call({_, :finish}, _, %{terminal: %Terminal{} = terminal} = s),
    do: {:reply, {:ok, terminal}, s}

  def handle_call({_, {:interrupt, _}}, _, %{terminal: %Terminal{}} = s),
    do: {:reply, {:error, :sealed}, s}

  def handle_call({_, operation}, _, %{terminal: %Terminal{}} = s) when operation != :stats,
    do: {:reply, {:error, :sealed}, s}

  def handle_call({_, :stats}, _, s) do
    case usage(s) do
      {:ok, usage} ->
        {:reply,
         {:ok,
          Map.merge(Map.from_struct(usage), %{
            pending_frames: s.count,
            pending_bytes: s.bytes,
            peak_pending_frames: s.peak_count,
            peak_pending_bytes: s.peak_bytes,
            limits: s.limits
          })}, s}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, s}
    end
  end

  def handle_call({_, :checkpoint}, _, s), do: answer_flush(flush(s))

  def handle_call({_, {:push, frame}}, _, s) do
    case StreamCursor.plan(s.cursor, {:frame, frame}) do
      {:ok, cursor, _} -> accept_frame(s, frame, cursor)
      {:reconcile, old} -> reconcile_frame(s, old)
      {:replay, {sequence, sample}} -> {:reply, {:error, {:replay, sequence, sample}}, s}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  def handle_call({_, {:gap, %{id: id} = gap}}, _, s) do
    case lookup(s, :gap, id) do
      {:ok, fingerprint} ->
        case StreamCursor.plan(s.cursor, {:gap_replay, gap, fingerprint}) do
          :duplicate ->
            reply_receipt(s)

          {:error, :duplicate_conflict} ->
            quarantine(s, "gap", id, Serialization.digest(gap), fingerprint)

          {:error, reason} ->
            {:reply, {:error, reason}, s}
        end

      :missing ->
        case StreamCursor.plan(s.cursor, {:gap, gap}) do
          {:ok, cursor, _} -> accept_gap(s, gap, cursor)
          {:error, reason} -> {:reply, {:error, reason}, s}
        end

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, s}
    end
  end

  def handle_call({_, {:gap, _}}, _, s), do: {:reply, {:error, :invalid_gap}, s}
  def handle_call({_, :finish}, _, s), do: end_recording(s, :finished, "source_finished")
  def handle_call({_, {:interrupt, reason}}, _, s), do: end_recording(s, :interrupted, reason)
  def handle_call(_, _, s), do: {:reply, {:error, :invalid_operation}, s}

  defp reconcile_frame(s, frame) do
    found =
      case Enum.find(s.pending, &(&1.sequence == frame.sequence)) do
        nil -> lookup(s, :frame, frame.sequence)
        pending -> {:ok, FrameFingerprint.of(pending)}
      end

    reconcile_found(s, frame, found)
  end

  defp reconcile_found(s, _, {:error, reason}), do: {:stop, :normal, {:error, reason}, s}

  defp reconcile_found(s, frame, found) do
    case StreamCursor.plan(s.cursor, {:frame_replay, frame, found}) do
      :duplicate ->
        reply_receipt(s)

      {:error, :duplicate_conflict} ->
        previous =
          case found do
            {:ok, fp} -> fp
            :missing -> nil
          end

        quarantine(
          s,
          "frame",
          Integer.to_string(frame.sequence),
          FrameFingerprint.of(frame),
          previous
        )

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  defp accept_frame(s, frame, cursor) do
    size = byte_size(frame.payload)

    cond do
      size > s.limits.pending_bytes ->
        {:reply, {:error, {:not_committed, :credit_limit}}, s}

      flush_before_frame?(s, frame, size) ->
        case flush(s) do
          {:ok, ready} -> accept_frame(ready, frame, cursor)
          failure -> answer_flush(failure)
        end

      true ->
        admit_frame(s, frame, cursor, size)
    end
  end

  defp flush_before_frame?(s, frame, size) do
    s.count > 0 and
      (s.bytes + size > s.limits.pending_bytes or s.count >= s.limits.pending_frames or
         hd(s.pending).config_epoch != frame.config_epoch)
  end

  defp admit_frame(s, frame, cursor, size) do
    {record, _, _} = Records.chunk_record(Enum.reverse([frame | s.pending]))

    extra = %{
      bytes: size,
      frames: 1,
      spans: if(frame.config_epoch == :unknown, do: 1, else: 0),
      commits: 1,
      encoded_bytes: RecordingLimits.encoded_record_bytes(record)
    }

    case capacity(s, cursor, extra, false) do
      :ok ->
        stage_frame(s, frame, cursor, size)

      {:error, {:outcome_unknown, _} = reason} ->
        {:stop, :normal, {:error, reason}, s}

      {:error, reason} ->
        {:reply, {:error, {:not_committed, {:capacity, reason}}}, s}
    end
  end

  defp stage_frame(s, frame, cursor, size) do
    next = %{
      s
      | cursor: cursor,
        pending: [frame | s.pending],
        count: s.count + 1,
        bytes: s.bytes + size,
        peak_count: max(s.peak_count, s.count + 1),
        peak_bytes: max(s.peak_bytes, s.bytes + size)
    }

    if next.count == s.limits.pending_frames or next.bytes == s.limits.pending_bytes,
      do: answer_flush(flush(next)),
      else: reply_receipt(arm_timer(next))
  end

  defp accept_gap(s, gap, cursor) do
    extra = %{
      bytes: 0,
      frames: 0,
      spans: 1,
      commits: 1,
      encoded_bytes: RecordingLimits.encoded_record_bytes(%{type: "gap", gap: gap})
    }

    case capacity(s, cursor, extra, true) do
      :ok ->
        case flush(s) do
          {:ok, ready} -> answer_flush(commit(ready, {:gap, gap}, cursor))
          failure -> answer_flush(failure)
        end

      {:error, {:outcome_unknown, _} = reason} ->
        {:stop, :normal, {:error, reason}, s}

      {:error, reason} ->
        {:reply, {:error, {:not_committed, {:capacity, reason}}}, s}
    end
  end

  defp capacity(s, cursor, extra, separate) do
    with {:ok, used} <- usage(s) do
      pending = %{
        bytes: s.bytes,
        frames: s.count,
        spans:
          if(separate and s.count > 0 and hd(s.pending).config_epoch == :unknown, do: 1, else: 0),
        commits: if(separate and s.count > 0, do: 1, else: 0),
        encoded_bytes:
          if separate and s.count > 0 do
            {record, _bytes, _segment} = Records.chunk_record(Enum.reverse(s.pending))
            RecordingLimits.encoded_record_bytes(record)
          else
            0
          end
      }

      RecordingLimits.admit(s.limits, used, pending, cursor, extra)
    end
  end

  defp usage(%{adapter: nil, terminal: %Terminal{recovered: recovered}}) do
    i = recovered.index

    {:ok,
     %Usage{
       raw_bytes: Enum.sum(Enum.map(i.segments, & &1.byte_size)),
       frame_count: Enum.sum(Enum.map(i.segments, &(&1.next_sequence - &1.first_sequence))),
       span_count: length(i.spans),
       journal_bytes: recovered.provenance.journal_bytes,
       journal_generation: i.journal_generation
     }}
  end

  defp usage(s) do
    case safely(fn -> s.storage.usage(s.adapter) end) do
      %Usage{} = usage ->
        values = Map.from_struct(usage)

        if Enum.all?(values, &nonnegative_usage_value?/1) and
             usage.journal_generation == s.durable.journal_generation and
             within_limits?(usage, s.limits),
           do: {:ok, usage},
           else: {:error, {:outcome_unknown, :invalid_storage_usage}}

      _ ->
        {:error, {:outcome_unknown, :invalid_storage_usage}}
    end
  end

  defp nonnegative_usage_value?({_, n}), do: is_integer(n) and n >= 0

  defp within_limits?(usage, limits) do
    usage.raw_bytes <= limits.artifact_bytes and usage.frame_count <= limits.frames and
      usage.span_count <= limits.spans and usage.journal_bytes <= limits.journal_bytes
  end

  defp lookup(s, family, key) do
    case safely(fn -> s.storage.lookup(s.adapter, family, key) end) do
      {:ok, digest} ->
        if ContractRules.digest?(digest),
          do: {:ok, digest},
          else: {:error, {:outcome_unknown, :invalid_storage_lookup}}

      :missing ->
        :missing

      _ ->
        {:error, {:outcome_unknown, :invalid_storage_lookup}}
    end
  end

  defp flush(%{pending: []} = s), do: {:ok, s}
  defp flush(s), do: commit(s, {:frames, Enum.reverse(s.pending)}, s.cursor)

  defp commit(s, event, cursor) do
    case transfer(s, fn -> s.storage.commit_batch(s.adapter, event) end) do
      {:ok, value, adopted} ->
        with {:ok, receipt} <- Receipt.parse(value),
             :ok <- Receipt.committed_successor(s.durable, receipt, cursor) do
          {:ok,
           disarm(%{adopted | durable: receipt, cursor: cursor, pending: [], count: 0, bytes: 0})}
        else
          _ -> {:error, {:outcome_unknown, :invalid_storage_receipt}, adopted}
        end

      {:error, reason, adopted} ->
        {:error, reason, adopted}
    end
  end

  defp transfer(s, operation) do
    case safely(operation) do
      %Transfer{handle: handle, result: result} ->
        adopted = %{s | adapter: handle}

        case result do
          {:ok, value} ->
            {:ok, value, adopted}

          {:error, {kind, _} = reason} when kind in [:not_committed, :outcome_unknown] ->
            {:error, reason, adopted}

          _ ->
            {:error, {:outcome_unknown, :invalid_storage_result}, adopted}
        end

      _ ->
        {:error, {:outcome_unknown, :invalid_storage_transfer}, s}
    end
  end

  defp reply_receipt(s) do
    receipt = %{
      s.durable
      | accepted_sequence: s.cursor.next_sequence,
        accepted_sample: s.cursor.next_sample
    }

    {:reply, {:ok, receipt}, s}
  end

  defp answer_flush({:ok, s}), do: reply_receipt(s)
  defp answer_flush({:error, {:not_committed, _} = reason, s}), do: {:reply, {:error, reason}, s}
  defp answer_flush({:error, reason, s}), do: {:stop, :normal, {:error, reason}, s}

  defp end_recording(s, disposition, reason) do
    valid = ContractRules.id?(reason) or (disposition == :failed and is_map(reason))

    if valid do
      case flush(s) do
        {:ok, ready} -> seal(ready, disposition, reason)
        failure -> answer_flush(failure)
      end
    else
      {:reply, {:error, :invalid_terminal_reason}, s}
    end
  end

  defp seal(s, disposition, reason) do
    case transfer(s, fn -> s.storage.seal(s.adapter, disposition, reason) end) do
      {:ok, %Terminal{} = terminal, adopted} ->
        with true <- terminal.index.terminal == disposition,
             {:ok, receipt} <-
               Receipt.terminal_receipt(terminal.index, terminal.recovered, s.durable),
             true <- receipt == terminal.receipt,
             :ok <- safely(fn -> adopted.storage.close(adopted.adapter) end) do
          {:reply, {:ok, terminal},
           disarm(%{adopted | adapter: nil, terminal: terminal, durable: receipt})}
        else
          _ -> {:stop, :normal, {:error, {:outcome_unknown, :invalid_storage_terminal}}, adopted}
        end

      {:ok, _, adopted} ->
        {:stop, :normal, {:error, {:outcome_unknown, :invalid_storage_terminal}}, adopted}

      {:error, {:not_committed, _} = reason, adopted} ->
        {:reply, {:error, reason}, adopted}

      {:error, reason, adopted} ->
        {:stop, :normal, {:error, reason}, adopted}
    end
  end

  defp quarantine(s, family, id, attempted, stored) do
    conflict = %{conflict: %{family: family, id: id, attempted: attempted, stored: stored}}

    case end_recording(s, :failed, conflict) do
      {:reply, {:ok, _}, next} -> {:reply, {:error, :duplicate_conflict}, next}
      {_, _, next} -> {:stop, :normal, {:error, {:outcome_unknown, :duplicate_conflict}}, next}
      {_, _, _, next} -> {:stop, :normal, {:error, {:outcome_unknown, :duplicate_conflict}}, next}
    end
  end

  defp arm_timer(%{limits: %{checkpoint_ms: :manual}} = s), do: s

  defp arm_timer(%{timer: nil} = s) do
    token = make_ref()

    %{
      s
      | timer: {Process.send_after(self(), {:checkpoint, token}, s.limits.checkpoint_ms), token}
    }
  end

  defp arm_timer(s), do: s
  defp disarm(%{timer: nil} = s), do: s

  defp disarm(%{timer: {timer, _}} = s) do
    Process.cancel_timer(timer)
    %{s | timer: nil}
  end

  @impl true
  def handle_info({:checkpoint, token}, %{timer: {_, token}, terminal: nil} = s) do
    if Process.alive?(s.owner) do
      case flush(%{s | timer: nil}) do
        {:ok, next} ->
          send(s.owner, {:med_ex_durable, self(), next.durable})
          {:noreply, next}

        {:error, reason, next} ->
          send(s.owner, {:med_ex_storage_failed, self(), reason})
          {:stop, :normal, next}
      end
    else
      {:stop, :normal, s}
    end
  end

  def handle_info({:checkpoint, _}, s), do: {:noreply, s}
  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_, %{adapter: nil}), do: :ok
  def terminate(_, s), do: safely(fn -> s.storage.close(s.adapter) end)

  defp safely(operation) do
    operation.()
  rescue
    _ -> {:error, {:outcome_unknown, :storage_exception}}
  catch
    _, _ -> {:error, {:outcome_unknown, :storage_exception}}
  end
end
