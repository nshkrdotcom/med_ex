defmodule MedEx.Storage.Records do
  @moduledoc false
  alias MedEx.{
    ContractRules,
    FrameFingerprint,
    IntegritySpan,
    SampleFrame,
    SegmentRef,
    Serialization,
    StreamCursor,
    StreamIndex
  }

  alias MedEx.Storage.Journal
  @max_frames 1_000_000
  @max_spans 100_000

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
    %{
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

  def durable_match?(actual, known) when is_map(known) do
    fields =
      ~w(stream_id source_epoch descriptor_ref fence journal_id journal_generation journal_digest durable_sequence durable_sample)a

    Enum.all?(fields, &(Map.fetch(actual, &1) == Map.fetch(known, &1)))
  end

  def durable_match?(_, _), do: false

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

  def apply_record(s, %{"type" => "chunk", "segment" => raw, "frames" => frames}, read)
      when is_list(frames) and length(frames) in 1..16 do
    seg =
      struct!(SegmentRef,
        key: raw["key"],
        sha256: raw["sha256"],
        descriptor_ref: raw["descriptor_ref"],
        byte_size: n(raw["byte_size"]),
        first_sample: n(raw["first_sample"]),
        end_sample: n(raw["end_sample"]),
        first_sequence: n(raw["first_sequence"]),
        next_sequence: n(raw["next_sequence"]),
        config_epoch:
          if(raw["config_epoch"] == "unknown", do: :unknown, else: n(raw["config_epoch"]))
      )

    with :ok <- SegmentRef.validate(seg),
         true <- seg.key == seg.sha256 <> ".pcm" and raw == Serialization.to_map(seg),
         true <-
           seg.descriptor_ref == s.cursor.stream.descriptor_ref and
             seg.first_sample == s.cursor.next_sample and
             seg.first_sequence == s.cursor.next_sequence,
         true <-
           map_size(s.frames) + length(frames) <= @max_frames and
             s.byte_total + seg.byte_size <= 536_870_912,
         {:ok, bytes} <- read.(seg),
         {:ok, next} <- verify_frames(s, seg, frames, bytes),
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

  def apply_record(s, %{"type" => "gap", "gap" => raw}, _read) do
    m = raw["span"]

    span = %IntegritySpan{
      stream_id: m["stream_id"],
      source_epoch: n(m["source_epoch"]),
      code: Serialization.enum!(m["code"], [:source_gap]),
      source: m["source"],
      first_sample: n(m["first_sample"]),
      end_sample: n(m["end_sample"]),
      event_ids: m["event_ids"],
      record_refs: m["record_refs"],
      context: Map.new(m["context"], fn {k, v} -> {k, Serialization.unscalar!(v)} end)
    }

    gap = %{
      id: raw["id"],
      span: span,
      first_sequence: n(raw["first_sequence"]),
      next_sequence: n(raw["next_sequence"]),
      irreversible: raw["irreversible"]
    }

    with true <- Serialization.to_map(gap) == raw and not Map.has_key?(s.gap_ids, gap.id),
         {:ok, cursor, _} <- StreamCursor.plan(s.cursor, {:gap, gap}),
         {:ok, next} <- add_span(s, span) do
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
          "conflict" => %{
            "family" => family,
            "id" => id,
            "attempted" => attempted,
            "stored" => stored
          }
        } = record,
        read
      ) do
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

  def apply_record(s, %{"type" => "terminal", "status" => raw, "reason" => reason}, _) do
    status = Serialization.enum!(raw, [:finished, :interrupted, :failed])

    if ContractRules.id?(reason) and (status != :finished or s.segments != []),
      do: {:ok, %{s | terminal: status, terminal_reason: reason}},
      else: {:error, :invalid_terminal}
  end

  def apply_record(_, _, _), do: {:error, :unknown_record}
  defp n(v), do: Serialization.integer!(v)

  defp add_span(s, span) when s.span_count < @max_spans,
    do: {:ok, %{s | spans: [span | s.spans], span_count: s.span_count + 1}}

  defp add_span(_, _), do: {:error, :span_limit}
  defp verify_frames(s, _seg, [], <<>>), do: {:ok, s}

  defp verify_frames(s, seg, [raw | rest], data) do
    count = n(raw["sample_count"])
    spec = s.cursor.stream
    length = count * length(spec.channels) * MedEx.StreamSpec.bytes_per_value(spec.encoding)

    with true <- length > 0 and length <= byte_size(data),
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
