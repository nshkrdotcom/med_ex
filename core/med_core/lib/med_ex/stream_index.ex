defmodule MedEx.StreamIndex do
  @moduledoc "Technical index shape; storage must separately verify object bytes and journal authority."
  alias MedEx.{ContractRules, IntegritySpan, SegmentRef, StreamSpec}

  @enforce_keys [
    :stream,
    :segments,
    :spans,
    :terminal,
    :journal_generation,
    :journal_digest,
    :fence
  ]
  defstruct @enforce_keys ++
              [
                schema_version: 1,
                journal_id: nil,
                terminal_reason: nil,
                next_sequence: 0,
                next_sample: 0,
                predecessor: nil,
                gaps: []
              ]

  @type t :: %__MODULE__{
          schema_version: 1,
          stream: MedEx.StreamSpec.t(),
          segments: [MedEx.SegmentRef.t()],
          spans: [MedEx.IntegritySpan.t()],
          terminal: :finished | :interrupted | :failed,
          journal_generation: non_neg_integer(),
          journal_digest: String.t(),
          fence: String.t()
        }
  def validate(%__MODULE__{} = i) do
    with :ok <- StreamSpec.validate(i.stream) do
      valid =
        valid_header?(i) and matching_records?(i) and coverage?(i.segments, i.spans) and
          journal_coverage?(i)

      if valid, do: :ok, else: {:error, :invalid_stream_index}
    end
  end

  def validate(_), do: {:error, :invalid_stream_index}

  defp valid_header?(i) do
    i.schema_version == 1 and i.terminal in [:finished, :interrupted, :failed] and
      (i.terminal != :finished or i.segments != []) and
      ContractRules.id?(i.fence) and
      ContractRules.uint?(i.journal_generation, 0xFFFFFFFFFFFFFFFF) and
      ContractRules.digest?(i.journal_digest)
  end

  defp matching_records?(i) do
    ContractRules.list?(i.segments, 100_000, &(SegmentRef.validate(&1) == :ok)) and
      ContractRules.list?(i.spans, 100_000, &(IntegritySpan.validate(&1) == :ok)) and
      Enum.all?(
        i.spans,
        &(&1.stream_id == i.stream.stream_id and &1.source_epoch == i.stream.source_epoch)
      ) and
      Enum.all?(i.segments, &segment_matches?(&1, i.stream))
  end

  # Detached/legacy shape validation has no journal cursor. A journal-backed
  # index additionally proves every gap sequence and its exact terminal boundary.
  defp journal_coverage?(%{journal_id: nil}), do: true

  defp journal_coverage?(i) do
    with true <- ContractRules.id?(i.journal_id) and ContractRules.id?(i.terminal_reason),
         true <- ContractRules.list?(i.gaps, 100_000, &gap?/1),
         true <- Enum.map(i.gaps, & &1.span) == Enum.filter(i.spans, &(&1.code == :source_gap)),
         true <- Enum.uniq_by(i.gaps, & &1.id) == i.gaps do
      journal_ranges_cover?(i)
    else
      _ -> false
    end
  end

  defp journal_ranges_cover?(i) do
    chunks =
      Enum.map(
        i.segments,
        &{&1.first_sample, &1.first_sequence, &1.end_sample, &1.next_sequence}
      )

    missing =
      Enum.map(
        i.gaps,
        &{&1.span.first_sample, &1.first_sequence, &1.span.end_sample, &1.next_sequence}
      )

    Enum.reduce_while(Enum.sort(chunks ++ missing), {0, 0}, fn {a, q, b, r}, current ->
      if current == {a, q}, do: {:cont, {b, r}}, else: {:halt, :invalid}
    end) == {i.next_sample, i.next_sequence}
  end

  defp gap?(%{
         id: id,
         irreversible: true,
         span: %IntegritySpan{code: :source_gap} = span,
         first_sequence: first,
         next_sequence: next
       }) do
    ContractRules.id?(id) and IntegritySpan.validate(span) == :ok and
      ContractRules.uint?(first, 0xFFFFFFFFFFFFFFFF) and
      ContractRules.uint?(next, 0xFFFFFFFFFFFFFFFF) and next >= first
  end

  defp gap?(_), do: false

  defp segment_matches?(s, stream) do
    sample_count = s.end_sample - s.first_sample
    frame_count = s.next_sequence - s.first_sequence

    s.descriptor_ref == stream.descriptor_ref and
      sample_count <= frame_count * stream.capabilities.max_frame_samples and
      s.byte_size ==
        sample_count * length(stream.channels) * StreamSpec.bytes_per_value(stream.encoding)
  end

  defp coverage?(segments, spans) do
    gaps = Enum.filter(spans, &(&1.code == :source_gap))

    ranges =
      Enum.map(segments, &{&1.first_sample, &1.end_sample}) ++
        Enum.map(gaps, &{&1.first_sample, &1.end_sample})

    covered =
      Enum.reduce_while(Enum.sort(ranges), 0, fn {first, last}, expected ->
        if first == expected, do: {:cont, last}, else: {:halt, false}
      end) != false

    sequenced =
      Enum.reduce_while(segments, {0, 0}, fn s, {sample, sequence} ->
        valid =
          s.first_sample >= sample and s.first_sequence >= sequence and
            (s.first_sample > sample or s.first_sequence == sequence)

        if valid, do: {:cont, {s.end_sample, s.next_sequence}}, else: {:halt, false}
      end) != false

    covered and sequenced
  end
end
