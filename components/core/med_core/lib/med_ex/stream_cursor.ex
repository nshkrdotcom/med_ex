defmodule MedEx.StreamCursor do
  @moduledoc "Pure plans. The caller commits proposed state only after the corresponding effect succeeds."
  alias MedEx.{ContractRules, IntegritySpan, SampleFrame, StreamSpec}
  @enforce_keys [:stream]
  defstruct @enforce_keys ++ [next_sequence: 0, next_sample: 0]
  @type t :: %__MODULE__{}
  def new(stream) do
    with :ok <- StreamSpec.validate(stream), do: {:ok, %__MODULE__{stream: stream}}
  end

  def plan(%__MODULE__{} = c, {:frame, %SampleFrame{} = frame}) do
    with :ok <- SampleFrame.validate(frame, c.stream) do
      cond do
        frame.sequence < c.next_sequence ->
          {:reconcile, frame}

        frame.sequence > c.next_sequence or frame.first_sample > c.next_sample ->
          {:replay, {c.next_sequence, c.next_sample}}

        frame.first_sample < c.next_sample ->
          {:error, :sample_overlap}

        frame.sequence == 0xFFFFFFFFFFFFFFFF ->
          {:error, :sequence_exhausted}

        true ->
          {:ok,
           %{
             c
             | next_sequence: frame.sequence + 1,
               next_sample: frame.first_sample + frame.sample_count
           }, [{:append, frame}]}
      end
    end
  end

  def plan(
        %__MODULE__{} = c,
        {:gap,
         %{
           id: id,
           span: %IntegritySpan{} = span,
           first_sequence: first,
           next_sequence: next,
           irreversible: true
         } = gap}
      ) do
    with :ok <- IntegritySpan.validate(span) do
      valid =
        ContractRules.id?(id) and span.code == :source_gap and span.event_ids == [] and
          {span.stream_id, span.source_epoch} == {c.stream.stream_id, c.stream.source_epoch} and
          span.first_sample == c.next_sample and first == c.next_sequence and
          ContractRules.uint?(next, 0xFFFFFFFFFFFFFFFF) and next >= first

      if valid do
        {:ok, %{c | next_sequence: next, next_sample: span.end_sample}, [{:gap, gap}]}
      else
        {:error, :invalid_gap}
      end
    end
  end

  def plan(%__MODULE__{} = cursor, {:frame_replay, %SampleFrame{} = frame, known}) do
    with :ok <- SampleFrame.validate(frame, cursor.stream),
         true <- frame.sequence < cursor.next_sequence do
      if known == {:ok, MedEx.FrameFingerprint.of(frame)},
        do: :duplicate,
        else: {:error, :duplicate_conflict}
    else
      _ -> {:error, :invalid_replay}
    end
  end

  def plan(
        %__MODULE__{} = cursor,
        {:gap_replay,
         %{
           id: id,
           span: %IntegritySpan{} = span,
           first_sequence: first,
           next_sequence: next,
           irreversible: true
         } = gap, fingerprint}
      ) do
    with :ok <- IntegritySpan.validate(span),
         true <- ContractRules.id?(id) and span.code == :source_gap and span.event_ids == [],
         true <-
           {span.stream_id, span.source_epoch} ==
             {cursor.stream.stream_id, cursor.stream.source_epoch},
         true <-
           ContractRules.uint?(first, 0xFFFFFFFFFFFFFFFF) and
             ContractRules.uint?(next, 0xFFFFFFFFFFFFFFFF),
         true <-
           next >= first and span.end_sample <= cursor.next_sample and
             next <= cursor.next_sequence do
      if MedEx.Serialization.digest(gap) == fingerprint,
        do: :duplicate,
        else: {:error, :duplicate_conflict}
    else
      _ -> {:error, :invalid_replay}
    end
  end

  def plan(_, _), do: {:error, :invalid_event}
end
