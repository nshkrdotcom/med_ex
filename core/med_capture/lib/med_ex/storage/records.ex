defmodule MedEx.Storage.Records do
  @moduledoc false
  alias MedEx.{
    ContractRules,
    FrameFingerprint,
    IntegritySpan,
    Receipt,
    RecordingLimits,
    SampleFrame,
    SegmentRef,
    Serialization,
    StreamCursor,
    StreamIndex
  }

  alias MedEx.Storage.Journal

  def initial(stream, fence) do
    {:ok, cursor} = StreamCursor.new(stream)

    %{
      cursor: cursor,
      fence: fence,
      journal_id: nil,
      generation: 0,
      digest: Journal.zero(),
      frames: %{},
      byte_total: 0,
      segments: [],
      spans: [],
      gap_ids: %{},
      gaps: [],
      span_count: 0,
      terminal: nil,
      terminal_reason: nil,
      predecessor: nil,
      prefixes: %{}
    }
  end

  def receipt(s) do
    %Receipt{
      stream_id: s.cursor.stream.stream_id,
      source_epoch: s.cursor.stream.source_epoch,
      descriptor_ref: s.cursor.stream.descriptor_ref,
      fence: s.fence,
      journal_id: s.journal_id,
      journal_generation: s.generation,
      journal_digest: s.digest,
      durable_sequence: s.cursor.next_sequence,
      durable_sample: s.cursor.next_sample,
      accepted_sequence: s.cursor.next_sequence,
      accepted_sample: s.cursor.next_sample
    }
  end

  def index(s) do
    %StreamIndex{
      stream: s.cursor.stream,
      fence: s.fence,
      journal_id: s.journal_id,
      journal_generation: s.generation,
      journal_digest: s.digest,
      segments: Enum.reverse(s.segments),
      spans: Enum.reverse(s.spans),
      gaps: Enum.reverse(s.gaps),
      terminal: s.terminal || :interrupted,
      terminal_reason: s.terminal_reason || "unknown_tail",
      predecessor: s.predecessor,
      next_sequence: s.cursor.next_sequence,
      next_sample: s.cursor.next_sample
    }
  end

  def chunk_record(frames) do
    first = hd(frames)
    last = List.last(frames)
    bytes = Enum.map(frames, & &1.payload) |> IO.iodata_to_binary()
    sha = Serialization.sha256(bytes)

    segment = %SegmentRef{
      key: sha <> ".pcm",
      sha256: sha,
      byte_size: byte_size(bytes),
      first_sample: first.first_sample,
      end_sample: last.first_sample + last.sample_count,
      first_sequence: first.sequence,
      next_sequence: last.sequence + 1,
      descriptor_ref: first.descriptor_ref,
      config_epoch: first.config_epoch
    }

    metadata =
      Enum.map(frames, fn f ->
        %{
          sample_count: f.sample_count,
          sequence: f.sequence,
          first_sample: f.first_sample,
          payload_sha256: Serialization.sha256(f.payload),
          fingerprint: FrameFingerprint.of(f)
        }
      end)

    {Serialization.to_map(%{type: "chunk", segment: segment, frames: metadata}), bytes, segment}
  end

  def apply_record(%{terminal: status}, _, _) when not is_nil(status),
    do: {:error, :record_after_terminal}

  def apply_record(s, %{"type" => "chunk", "segment" => raw, "frames" => frames} = record, read)
      when map_size(record) == 3 and is_list(frames) and length(frames) in 1..16 do
    with {:ok, seg} <- Serialization.segment_ref(raw),
         true <- seg.key == seg.sha256 <> ".pcm",
         true <-
           seg.descriptor_ref == s.cursor.stream.descriptor_ref and
             seg.first_sample == s.cursor.next_sample and
             seg.first_sequence == s.cursor.next_sequence,
         true <-
           map_size(s.frames) + length(frames) <= RecordingLimits.maximum().frames and
             s.byte_total + seg.byte_size <= RecordingLimits.maximum().artifact_bytes,
         {:ok, bytes} <- read.(seg),
         {:ok, next} <- verify_frames(s, seg, frames, bytes),
         true <- duration?(next.cursor),
         true <-
           {seg.end_sample, seg.next_sequence} ==
             {next.cursor.next_sample, next.cursor.next_sequence} do
      next = %{next | segments: [seg | next.segments], byte_total: s.byte_total + seg.byte_size}

      if seg.config_epoch == :unknown do
        span = %IntegritySpan{
          stream_id: s.cursor.stream.stream_id,
          source_epoch: s.cursor.stream.source_epoch,
          code: :configuration_unknown,
          source: "frame_header",
          first_sample: seg.first_sample,
          end_sample: seg.end_sample
        }

        add_span(next, span)
      else
        {:ok, next}
      end
    else
      false -> {:error, :invalid_chunk}
      error -> error
    end
  end

  def apply_record(s, %{"type" => "gap", "gap" => raw} = record, _read)
      when map_size(record) == 2 do
    with {:ok, gap} <- Serialization.gap(raw),
         true <- not Map.has_key?(s.gap_ids, gap.id),
         {:ok, cursor, _} <- StreamCursor.plan(s.cursor, {:gap, gap}),
         true <- duration?(cursor),
         {:ok, next} <- add_span(s, gap.span) do
      {:ok,
       %{
         next
         | cursor: cursor,
           gaps: [gap | s.gaps],
           gap_ids: Map.put(s.gap_ids, gap.id, Serialization.digest(gap))
       }}
    else
      false -> {:error, :invalid_gap}
      error -> error
    end
  end

  def apply_record(
        s,
        %{
          "type" => "terminal",
          "status" => "failed",
          "reason" => "duplicate_conflict",
          "conflict" =>
            %{
              "family" => family,
              "id" => id,
              "attempted" => attempted,
              "stored" => stored
            } = conflict
        } = record,
        read
      )
      when map_size(record) == 4 and map_size(conflict) == 4 do
    known =
      case family do
        "frame" -> Map.get(s.frames, n(id))
        "gap" -> Map.get(s.gap_ids, id)
        _ -> :invalid
      end

    if ContractRules.id?(id) and ContractRules.digest?(attempted) and known == stored and
         attempted != stored do
      # The replay's claimed sample range may itself conflict. Refer to the
      # operation identity, without inventing a verified sample interval.
      span = %IntegritySpan{
        stream_id: s.cursor.stream.stream_id,
        source_epoch: s.cursor.stream.source_epoch,
        event_ids: [id],
        code: :duplicate_conflict,
        source: "writer_replay_comparison",
        context: %{
          "identity_family" => family,
          "attempted_sha256" => attempted,
          "stored_sha256" => stored || :unknown
        }
      }

      with {:ok, next} <- add_span(s, span),
           do: apply_record(next, Map.delete(record, "conflict"), read)
    else
      {:error, :invalid_conflict_record}
    end
  end

  def apply_record(s, %{"type" => "terminal", "status" => raw, "reason" => reason} = record, _)
      when map_size(record) == 3 do
    status = Serialization.enum!(raw, [:finished, :interrupted, :failed])

    if ContractRules.id?(reason) and (status != :finished or s.segments != []),
      do: {:ok, %{s | terminal: status, terminal_reason: reason}},
      else: {:error, :invalid_terminal}
  end

  def apply_record(_, _, _), do: {:error, :unknown_record}
  defp n(v), do: Serialization.integer!(v)

  defp duration?(cursor) do
    {rate, divisor} = cursor.stream.sample_rate
    cursor.next_sample * divisor <= RecordingLimits.maximum().duration_seconds * rate
  end

  defp add_span(s, span) do
    if s.span_count < RecordingLimits.maximum().spans,
      do: {:ok, %{s | spans: [span | s.spans], span_count: s.span_count + 1}},
      else: {:error, :span_limit}
  end

  defp verify_frames(s, _seg, [], <<>>), do: {:ok, s}

  defp verify_frames(s, seg, [raw | rest], data) do
    count = n(raw["sample_count"])
    spec = s.cursor.stream
    length = count * length(spec.channels) * MedEx.StreamSpec.bytes_per_value(spec.encoding)

    with true <- is_map(raw) and map_size(raw) == 5 and length > 0 and length <= byte_size(data),
         <<bytes::binary-size(^length), tail::binary>> <- data,
         f = %SampleFrame{
           stream_id: spec.stream_id,
           source_epoch: spec.source_epoch,
           descriptor_ref: spec.descriptor_ref,
           sequence: n(raw["sequence"]),
           first_sample: n(raw["first_sample"]),
           sample_count: count,
           config_epoch: seg.config_epoch,
           payload: bytes
         },
         {:ok, cursor, _} <- StreamCursor.plan(s.cursor, {:frame, f}),
         fp = FrameFingerprint.of(f),
         true <- raw["payload_sha256"] == Serialization.sha256(bytes) and raw["fingerprint"] == fp do
      verify_frames(
        %{s | cursor: cursor, frames: Map.put(s.frames, f.sequence, fp)},
        seg,
        rest,
        tail
      )
    else
      _ -> {:error, :invalid_frame_record}
    end
  end

  defp verify_frames(_, _, _, _), do: {:error, :chunk_length}
end
