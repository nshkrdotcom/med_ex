defmodule MedEx.StreamWriter do
  @moduledoc """
  One temporary writer per authenticated stream attempt. The host issues the
  fence, selects a trusted directory and supervises the worker. The owner uses
  synchronous calls to bound one ingress stream. Push receipts distinguish
  accepted (volatile) from journal-backed durable boundaries. A timer checkpoint
  sends the owner `{:med_ex_durable, writer, receipt}`. A call timeout or process
  exit is an unknown outcome. Reconcile storage before granting a replacement.

  With `checkpoint_ms: :manual`, owner loss closes storage without committing
  pending frames or writing a terminal record. The host controls explicit writes.
  """
  use GenServer, restart: :temporary
  alias MedEx.{ContractRules, FrameFingerprint, Serialization, StreamCursor, StreamIndex}
  alias MedEx.Storage.File, as: Posix

  @defaults %{
    pending_bytes: 262_144,
    pending_frames: 16,
    checkpoint_ms: 250,
    duration_seconds: 1_800,
    artifact_bytes: 536_870_912
  }

  @timeout 5_000
  @finish_timeout 20_000
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, timeout: Keyword.get(opts, :open_timeout, 30_000))

  def push(pid, frame), do: call(pid, :bound, {:push, frame}, @timeout)
  def push(pid, fence, frame), do: push(pid, fence, frame, @timeout)
  def push(pid, fence, frame, timeout), do: call(pid, fence, {:push, frame}, timeout)
  def checkpoint(pid, timeout \\ @timeout), do: call(pid, :bound, :checkpoint, timeout)
  def record_gap(pid, gap, timeout \\ @timeout), do: call(pid, :bound, {:gap, gap}, timeout)
  def finish(pid, timeout \\ @finish_timeout), do: call(pid, :bound, :finish, timeout)

  def interrupt(pid, reason, timeout \\ @finish_timeout),
    do: call(pid, :bound, {:interrupt, reason}, timeout)

  def stats(pid), do: call(pid, :bound, :stats, @timeout)
  def receipt(pid, timeout \\ @timeout), do: call(pid, :bound, :receipt, timeout)

  defp call(pid, fence, request, timeout) when is_integer(timeout) and timeout > 0 do
    GenServer.call(pid, {fence, request}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, {:outcome_unknown, :timeout}}
    :exit, {reason, _} -> {:error, {:outcome_unknown, reason}}
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    stream = Keyword.fetch!(opts, :stream)
    fence = Keyword.fetch!(opts, :fence)
    storage = Keyword.get(opts, :storage, Posix)

    with true <- is_pid(owner) and ContractRules.id?(fence),
         {:ok, limits} <- limits(opts[:limits] || %{}),
         {:ok, cursor} <- StreamCursor.new(stream),
         :ok <- verify_descriptor(stream),
         {:ok, adapter, receipt} <- storage.open(opts) do
      if valid_receipt?(receipt, stream, fence) and
           receipt.accepted_sequence == receipt.durable_sequence and
           receipt.accepted_sample == receipt.durable_sample do
        {:ok,
         %{
           owner: owner,
           monitor: Process.monitor(owner),
           fence: fence,
           cursor: %{
             cursor
             | next_sequence: receipt.durable_sequence,
               next_sample: receipt.durable_sample
           },
           limits: limits,
           storage: storage,
           adapter: adapter,
           durable: receipt,
           pending: [],
           bytes: 0,
           count: 0,
           peak_count: 0,
           peak_bytes: 0,
           timer: nil
         }}
      else
        storage.close(adapter)
        {:error, :invalid_storage_receipt}
      end
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_owner_or_fence}
    end
  end

  defp verify_descriptor(stream) do
    if stream.descriptor_ref == Serialization.descriptor_ref(stream),
      do: :ok,
      else: {:error, :invalid_descriptor}
  end

  defp limits(list) when is_list(list), do: limits(Map.new(list))

  defp limits(map) when is_map(map) do
    if Enum.all?(map, fn
         {:checkpoint_ms, :manual} ->
           true

         {key, value} ->
           Map.has_key?(@defaults, key) and is_integer(value) and
             value in 1..Map.fetch!(@defaults, key)
       end) do
      {:ok, Map.merge(@defaults, map)}
    else
      {:error, :invalid_limits}
    end
  end

  defp limits(_), do: {:error, :invalid_limits}
  @impl true
  def handle_call(_, {caller, _}, s) when caller != s.owner, do: {:reply, {:error, :not_owner}, s}

  def handle_call({fence, _}, _, s) when fence != :bound and fence != s.fence,
    do: {:reply, {:error, :stale_fence}, s}

  def handle_call({_, :stats}, _, s) do
    {:reply,
     Map.merge(s.storage.usage(s.adapter), %{
       pending_frames: s.count,
       pending_bytes: s.bytes,
       peak_pending_frames: s.peak_count,
       peak_pending_bytes: s.peak_bytes,
       limits: s.limits
     }), s}
  end

  def handle_call({_, :receipt}, _, s), do: reply_receipt(s)
  def handle_call({_, :checkpoint}, _, s), do: answer_flush(flush(s))

  def handle_call({_, {:push, frame}}, _, s) do
    case StreamCursor.plan(s.cursor, {:frame, frame}) do
      {:ok, cursor, _} ->
        accept(s, frame, cursor)

      {:reconcile, old} ->
        match =
          case Enum.find(s.pending, &(&1.sequence == old.sequence)) do
            nil -> s.storage.lookup(s.adapter, :frame, old.sequence)
            f -> {:ok, FrameFingerprint.of(f)}
          end

        incoming = FrameFingerprint.of(old)

        if match == {:ok, incoming},
          do: reply_receipt(s),
          else: quarantine(s, "frame", to_string(old.sequence), incoming, match)

      {:replay, {seq, sample}} ->
        {:reply, {:error, {:replay, seq, sample}}, s}

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  def handle_call({_, {:gap, %{id: id} = gap}}, _, s) do
    case s.storage.lookup(s.adapter, :gap, id) do
      {:ok, fp} ->
        incoming = Serialization.digest(gap)

        if incoming == fp,
          do: reply_receipt(s),
          else: quarantine(s, "gap", id, incoming, {:ok, fp})

      :missing ->
        accept_gap(s, gap)
    end
  end

  def handle_call({_, {:gap, _}}, _, s), do: {:reply, {:error, :invalid_gap}, s}
  def handle_call({_, :finish}, _, s), do: end_recording(s, :finished, "source_finished")

  def handle_call({_, {:interrupt, reason}}, _, s) when is_atom(reason),
    do: end_recording(s, :interrupted, Atom.to_string(reason))

  def handle_call({_, {:interrupt, reason}}, _, s), do: end_recording(s, :interrupted, reason)

  defp accept_gap(s, gap) do
    case StreamCursor.plan(s.cursor, {:gap, gap}) do
      {:ok, cursor, _} ->
        case gap_capacity(s, cursor) do
          :ok -> flush_gap(s, gap, cursor)
          {:error, reason} -> capacity_stop(s, reason)
        end

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  defp gap_capacity(s, cursor) do
    cond do
      over_duration?(cursor, s.limits) -> {:error, "duration_limit"}
      s.durable.journal_generation >= 99_997 -> {:error, "journal_limit"}
      s.storage.usage(s.adapter).span_count >= 99_999 -> {:error, "integrity_span_limit"}
      true -> :ok
    end
  end

  defp flush_gap(s, gap, cursor) do
    case flush(s) do
      {:ok, ready} -> answer_flush(commit(ready, {:gap, gap}, cursor))
      failure -> answer_flush(failure)
    end
  end

  defp accept(s, frame, cursor) do
    size = byte_size(frame.payload)

    case frame_capacity(s, frame, cursor, size) do
      :ok -> buffer_frame(s, frame, cursor, size)
      {:error, reason} -> capacity_stop(s, reason)
    end
  end

  defp frame_capacity(s, frame, cursor, size) do
    usage = s.storage.usage(s.adapter)

    cond do
      over_duration?(cursor, s.limits) ->
        {:error, "duration_limit"}

      usage.raw_bytes + s.bytes + size > s.limits.artifact_bytes ->
        {:error, "artifact_limit"}

      usage.frame_count + s.count >= 1_000_000 ->
        {:error, "frame_limit"}

      usage.span_count >= 99_999 and frame.config_epoch == :unknown ->
        {:error, "integrity_span_limit"}

      s.durable.journal_generation >= 99_998 ->
        {:error, "journal_limit"}

      true ->
        :ok
    end
  end

  defp buffer_frame(s, frame, cursor, size) do
    cond do
      size > s.limits.pending_bytes ->
        {:reply, {:error, :credit_limit}, s}

      flush_before_buffering?(s, frame, size) ->
        case flush(s) do
          {:ok, ready} -> accept(ready, frame, cursor)
          error -> answer_flush(error)
        end

      true ->
        enqueue_frame(s, frame, cursor, size)
    end
  end

  defp flush_before_buffering?(s, frame, size) do
    s.bytes + size > s.limits.pending_bytes or s.count == s.limits.pending_frames or
      (s.pending != [] and hd(s.pending).config_epoch != frame.config_epoch)
  end

  defp enqueue_frame(s, frame, cursor, size) do
    next = %{
      s
      | cursor: cursor,
        bytes: s.bytes + size,
        count: s.count + 1,
        peak_count: max(s.peak_count, s.count + 1),
        peak_bytes: max(s.peak_bytes, s.bytes + size),
        pending: [frame | s.pending]
    }

    if next.count == s.limits.pending_frames or next.bytes == s.limits.pending_bytes,
      do: answer_flush(flush(next)),
      else: reply_receipt(arm_timer(next))
  end

  defp over_duration?(cursor, limits) do
    {rate, divisor} = cursor.stream.sample_rate
    cursor.next_sample * divisor > limits.duration_seconds * rate
  end

  defp capacity_stop(s, reason) do
    case end_recording(s, :interrupted, reason) do
      {:stop, :normal, {:ok, index}, next} ->
        send(s.owner, {:med_ex_interrupted, self(), index})
        {:stop, :normal, {:error, {:capacity, reason}}, next}

      failure ->
        failure
    end
  end

  defp arm_timer(%{limits: %{checkpoint_ms: :manual}} = s), do: s

  defp arm_timer(%{timer: nil} = s) do
    token = make_ref()
    timer = Process.send_after(self(), {:checkpoint, token}, s.limits.checkpoint_ms)
    %{s | timer: {timer, token}}
  end

  defp arm_timer(s), do: s
  defp disarm(%{timer: nil} = s), do: s

  defp disarm(%{timer: {timer, _}} = s) do
    Process.cancel_timer(timer)
    %{s | timer: nil}
  end

  defp flush(%{pending: []} = s), do: {:ok, s}
  defp flush(s), do: commit(s, {:frames, Enum.reverse(s.pending)}, s.cursor)

  defp commit(s, event, cursor) do
    case s.storage.commit_batch(s.adapter, event) do
      {:ok, adapter, r} ->
        if committed_receipt?(r, s, cursor) do
          {:ok,
           disarm(%{
             s
             | adapter: adapter,
               durable: r,
               cursor: cursor,
               pending: [],
               count: 0,
               bytes: 0
           })}
        else
          {:error, {:outcome_unknown, :invalid_storage_receipt}, s}
        end

      {:error, {kind, _} = error} when kind in [:not_committed, :outcome_unknown] ->
        {:error, error, s}

      other ->
        {:error, {:outcome_unknown, other}, s}
    end
  end

  defp committed_receipt?(r, s, cursor) do
    valid_receipt?(r, cursor.stream, s.fence) and r.journal_id == s.durable.journal_id and
      r.journal_generation == s.durable.journal_generation + 1 and
      r.journal_digest != s.durable.journal_digest and
      {r.durable_sequence, r.durable_sample} == {cursor.next_sequence, cursor.next_sample} and
      {r.accepted_sequence, r.accepted_sample} == {r.durable_sequence, r.durable_sample}
  end

  defp valid_receipt?(r, spec, fence) when is_map(r) do
    case Serialization.receipt(Serialization.to_map(r)) do
      {:ok, ^r} ->
        {r.fence, r.stream_id, r.source_epoch, r.descriptor_ref} ==
          {fence, spec.stream_id, spec.source_epoch, spec.descriptor_ref}

      _ ->
        false
    end
  end

  defp valid_receipt?(_, _, _), do: false

  defp reply_receipt(s) do
    r = %{
      s.durable
      | accepted_sample: s.cursor.next_sample,
        accepted_sequence: s.cursor.next_sequence
    }

    {:reply, {:ok, r}, s}
  end

  defp answer_flush({:ok, s}), do: reply_receipt(s)

  defp answer_flush({:error, {:not_committed, _} = reason, s}),
    do: {:reply, {:error, reason}, arm_if_needed(s)}

  defp answer_flush({:error, reason, s}), do: {:stop, :normal, {:error, reason}, s}
  defp arm_if_needed(%{pending: []} = s), do: s
  defp arm_if_needed(s), do: arm_timer(s)

  defp quarantine(s, family, id, attempted, prior) do
    # The changed identity receives no receipt. Stop admitting this attempt even
    # when persistence of its failed terminal outcome cannot be established.
    stored =
      case prior do
        {:ok, fp} -> fp
        :missing -> nil
      end

    conflict = %{family: family, id: id, attempted: attempted, stored: stored}

    case end_recording(s, :failed, %{conflict: conflict}) do
      {:stop, _, {:ok, _}, next} ->
        {:stop, :normal, {:error, :duplicate_conflict}, next}

      {_, _, {:error, reason}, next} ->
        {:stop, :normal, {:error, {:outcome_unknown, reason}}, next}

      {:reply, {:error, reason}, next} ->
        {:stop, :normal, {:error, {:outcome_unknown, reason}}, next}
    end
  end

  defp end_recording(s, terminal, reason) do
    if (terminal == :failed and is_map(reason)) or ContractRules.id?(reason) do
      case flush(s) do
        {:ok, ready} -> seal_recording(ready, terminal, reason)
        failure -> answer_flush(failure)
      end
    else
      {:reply, {:error, :invalid_terminal_reason}, s}
    end
  end

  defp seal_recording(s, terminal, reason) do
    case s.storage.seal(s.adapter, terminal, reason) do
      {:ok, %StreamIndex{} = index} ->
        if sealed_index?(index, s, terminal),
          do: {:stop, :normal, {:ok, index}, s},
          else: {:stop, :normal, {:error, {:outcome_unknown, :invalid_storage_index}}, s}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, s}
    end
  end

  defp sealed_index?(i, s, terminal) do
    StreamIndex.validate(i) == :ok and i.fence == s.fence and
      i.stream == s.cursor.stream and i.terminal == terminal and
      i.journal_id == s.durable.journal_id and
      i.journal_generation == s.durable.journal_generation + 1 and
      {i.next_sequence, i.next_sample} == {s.cursor.next_sequence, s.cursor.next_sample}
  end

  @impl true
  def handle_info({:checkpoint, token}, %{timer: {_, token}} = s) do
    case flush(%{s | timer: nil}) do
      {:ok, next} ->
        send(s.owner, {:med_ex_durable, self(), next.durable})
        {:noreply, next}

      {:error, reason, next} ->
        send(s.owner, {:med_ex_storage_failed, self(), reason})
        {:stop, :normal, next}
    end
  end

  def handle_info({:checkpoint, _}, s), do: {:noreply, s}

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{monitor: ref, limits: %{checkpoint_ms: :manual}} = s
      ),
      do: {:stop, :normal, s}

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = s) do
    # If flushing fails, the host must recover the verified prefix.
    result = end_recording(s, :interrupted, "owner_lost")
    {:stop, :normal, elem(result, tuple_size(result) - 1)}
  end

  @impl true
  def terminate(_, s), do: s.storage.close(s.adapter)
end
