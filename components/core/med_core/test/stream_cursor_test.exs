defmodule MedEx.StreamCursorTest do
  use ExUnit.Case, async: true
  alias MedEx.{IntegritySpan, SampleFrame, StreamCursor, StreamSpec}

  setup do
    s = %StreamSpec{
      acquisition_id: "a",
      source_ref: "device",
      boot_id: "boot",
      stream_id: "ecg",
      source_epoch: 0,
      descriptor_ref: String.duplicate("a", 64),
      modality: "medex:ecg",
      encoding: :s16le,
      channels: [%{id: "II", label: "II", unit: "uV", calibration: :unknown}],
      sample_rate: {250, 1},
      capabilities: %{
        encodings: [:s16le],
        max_frame_samples: 25,
        max_payload_bytes: 64_000,
        replay: :durable_spool,
        commands: []
      }
    }

    {:ok, c} = StreamCursor.new(s)

    f = %SampleFrame{
      stream_id: "ecg",
      source_epoch: 0,
      descriptor_ref: s.descriptor_ref,
      sequence: 0,
      first_sample: 0,
      sample_count: 2,
      config_epoch: 0,
      payload: <<1, 0, 2, 0>>
    }

    %{cursor: c, frame: f}
  end

  test "planning appends is pure and old identities require journal reconciliation", %{
    cursor: c,
    frame: f
  } do
    assert {:ok, next, [{:append, ^f}]} = StreamCursor.plan(c, {:frame, f})
    assert {next.next_sequence, next.next_sample} == {1, 2}
    assert {c.next_sequence, c.next_sample} == {0, 0}
    assert {:reconcile, ^f} = StreamCursor.plan(next, {:frame, f})
  end

  test "a future frame requests replay and only an explicit gap advances", %{cursor: c, frame: f} do
    future = %{f | sequence: 2, first_sample: 4}
    assert {:replay, {0, 0}} = StreamCursor.plan(c, {:frame, future})

    span = %IntegritySpan{
      stream_id: "ecg",
      source_epoch: 0,
      first_sample: 0,
      end_sample: 4,
      code: :source_gap,
      source: "device",
      record_refs: ["loss-1"]
    }

    gap = %{id: "loss-1", span: span, first_sequence: 0, next_sequence: 2, irreversible: true}
    assert {:ok, next, [{:gap, ^gap}]} = StreamCursor.plan(c, {:gap, gap})
    assert {:ok, done, [{:append, ^future}]} = StreamCursor.plan(next, {:frame, future})
    assert {done.next_sequence, done.next_sample} == {3, 6}
    assert {:error, _} = StreamCursor.plan(c, {:gap, %{gap | irreversible: false}})

    assert :duplicate =
             StreamCursor.plan(next, {:gap_replay, gap, MedEx.Serialization.digest(gap)})

    assert {:error, :duplicate_conflict} =
             StreamCursor.plan(next, {:gap_replay, gap, String.duplicate("f", 64)})

    for malformed <- [
          %{span: span},
          Map.delete(gap, :next_sequence),
          %{gap | next_sequence: "2"},
          %{gap | irreversible: false}
        ] do
      assert {:error, _} =
               StreamCursor.plan(next, {:gap_replay, malformed, String.duplicate("f", 64)})
    end
  end
end
