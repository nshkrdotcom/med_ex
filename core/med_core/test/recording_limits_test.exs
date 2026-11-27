defmodule MedEx.RecordingLimitsTest do
  use ExUnit.Case, async: true
  alias MedEx.RecordingLimits, as: L

  test "maximum-shape terminal arithmetic reserves the canonical encoded bytes" do
    limits = L.maximum()

    assert limits.frames == 1_000_000 and limits.spans == 100_000 and
             limits.generations == 100_000

    assert limits.pending_frames == 16 and limits.pending_bytes == 262_144
    assert limits.duration_seconds == 1800 and limits.artifact_bytes == 536_870_912
    assert L.terminal_reserve_bytes() < L.max_record_bytes() + L.envelope_bytes()

    for reason <- ["normal", String.duplicate(<<0>>, 256)] do
      bytes = L.encoded_record_bytes(%{type: "terminal", status: "interrupted", reason: reason})
      assert bytes <= L.terminal_reserve_bytes()
    end
  end

  test "invalid or overflowing budgets cannot relax format ceilings" do
    for options <- [
          %{frames: 1_000_001},
          %{generations: 2},
          %{pending_bytes: 0},
          %{unknown: 1},
          [] ++ [:invalid],
          nil
        ] do
      assert {:error, :invalid_limits} = L.new(options)
    end

    assert {:ok, %{checkpoint_ms: :manual}} = L.new(%{checkpoint_ms: :manual})
  end

  test "real maximum arithmetic reserves frames, spans, generations, bytes and duration without allocation" do
    limits = L.maximum()

    usage = %{
      raw_bytes: 0,
      frame_count: 0,
      span_count: 0,
      journal_bytes: 0,
      journal_generation: 1
    }

    pending = %{bytes: 0, frames: 0, spans: 0, commits: 0, encoded_bytes: 0}
    extra = %{bytes: 1, frames: 1, spans: 0, commits: 1, encoded_bytes: 100}
    cursor = %{stream: %{sample_rate: {48_000, 1}}, next_sample: 960}

    for delta <- [-1, 0, 1] do
      frames = %{usage | frame_count: limits.frames - 1 + delta}
      expected = if delta <= 0, do: :ok, else: {:error, :frame_limit}
      assert L.admit(limits, frames, pending, cursor, extra) == expected
      bytes = %{usage | raw_bytes: limits.artifact_bytes - 1 + delta}
      expected = if delta <= 0, do: :ok, else: {:error, :artifact_limit}
      assert L.admit(limits, bytes, pending, cursor, extra) == expected
      generations = %{usage | journal_generation: limits.generations - 2 + delta}
      expected = if delta <= 0, do: :ok, else: {:error, :journal_limit}
      assert L.admit(limits, generations, pending, cursor, extra) == expected

      journal = %{
        usage
        | journal_bytes: limits.journal_bytes - L.terminal_reserve_bytes() - 100 + delta
      }

      assert L.admit(limits, journal, pending, cursor, extra) == expected
      duration = %{cursor | next_sample: 48_000 * limits.duration_seconds + delta}
      expected = if delta <= 0, do: :ok, else: {:error, :duration_limit}
      assert L.admit(limits, usage, pending, duration, extra) == expected
      spans = %{usage | span_count: limits.spans - 1 + delta}
      expected = if delta <= 0, do: :ok, else: {:error, :integrity_span_limit}
      assert L.admit(limits, spans, pending, cursor, extra) == expected
    end

    huge = 0xFFFFFFFFFFFFFFFF
    exact = %{stream: %{sample_rate: {huge, huge}}, next_sample: limits.duration_seconds}
    assert :ok = L.admit(limits, usage, pending, exact, extra)

    assert {:error, :duration_limit} =
             L.admit(limits, usage, pending, %{exact | next_sample: exact.next_sample + 1}, extra)
  end
end
