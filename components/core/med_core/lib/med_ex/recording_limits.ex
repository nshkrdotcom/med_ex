defmodule MedEx.RecordingLimits do
  @moduledoc "One bounded recording budget shared by admission, journal and recovery."
  defstruct pending_bytes: 262_144,
            pending_frames: 16,
            checkpoint_ms: 250,
            duration_seconds: 1_800,
            artifact_bytes: 536_870_912,
            frames: 1_000_000,
            spans: 100_000,
            generations: 100_000,
            journal_bytes: 268_435_456,
            predecessor_depth: 32

  @type t :: %__MODULE__{}
  @max_record 65_424
  @envelope_bytes 112

  def new(%__MODULE__{} = limits), do: new(Map.from_struct(limits))

  def new(options) when is_list(options) do
    if Keyword.keyword?(options) and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))),
       do: new(Map.new(options)),
       else: {:error, :invalid_limits}
  end

  def new(options) when is_map(options) do
    maximum = Map.from_struct(%__MODULE__{})

    valid =
      Enum.all?(options, fn
        {:checkpoint_ms, :manual} ->
          true

        {key, value} ->
          Map.has_key?(maximum, key) and is_integer(value) and value > 0 and
            value <= Map.fetch!(maximum, key)
      end)

    limits = if valid, do: struct!(__MODULE__, options)

    if valid and limits.generations >= 3 and limits.spans >= 1 and
         limits.journal_bytes >= terminal_reserve_bytes() + 3 * @envelope_bytes,
       do: {:ok, limits},
       else: {:error, :invalid_limits}
  end

  def new(_), do: {:error, :invalid_limits}
  def maximum, do: %__MODULE__{}
  def max_record_bytes, do: @max_record
  def envelope_bytes, do: @envelope_bytes

  def encoded_record_bytes(record),
    do: byte_size(MedEx.Serialization.bytes(record)) + @envelope_bytes

  def terminal_reserve_bytes do
    # Longest permitted ID in canonical JSON: each NUL occupies six bytes.
    id = String.duplicate(<<0>>, 256)
    digest = String.duplicate("f", 64)

    max(
      encoded_record_bytes(%{type: "terminal", status: "interrupted", reason: id}),
      encoded_record_bytes(%{
        type: "terminal",
        status: "failed",
        reason: "duplicate_conflict",
        conflict: %{family: "frame", id: id, attempted: digest, stored: digest}
      })
    )
  end

  @doc "Reserve a pending flush and terminal envelope before accepting another source record."
  def admit(%__MODULE__{} = limits, usage, pending, cursor, extra) do
    {rate, divisor} = cursor.stream.sample_rate

    cond do
      cursor.next_sample * divisor > limits.duration_seconds * rate ->
        {:error, :duration_limit}

      usage.raw_bytes + pending.bytes + extra.bytes > limits.artifact_bytes ->
        {:error, :artifact_limit}

      usage.frame_count + pending.frames + extra.frames > limits.frames ->
        {:error, :frame_limit}

      usage.span_count + pending.spans + extra.spans >= limits.spans ->
        {:error, :integrity_span_limit}

      usage.journal_generation + pending.commits + extra.commits + 1 > limits.generations ->
        {:error, :journal_limit}

      usage.journal_bytes + pending.encoded_bytes + extra.encoded_bytes + terminal_reserve_bytes() >
          limits.journal_bytes ->
        {:error, :journal_limit}

      true ->
        :ok
    end
  end
end
