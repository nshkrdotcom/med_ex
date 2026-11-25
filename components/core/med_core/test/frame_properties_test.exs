defmodule MedEx.FramePropertiesTest do
  use ExUnit.Case, async: true
  alias MedEx.{SampleFrame, StreamCursor, StreamSpec}

  test "whole-row framing and monotone coordinates across supported layouts" do
    :rand.seed(:exsss, {16, 24, 32})

    for encoding <- [:s16le, :s24le, :s32le], channels <- [1, 2, 12, 32] do
      spec = %StreamSpec{
        acquisition_id: "a",
        source_ref: "d",
        boot_id: "b",
        stream_id: "w",
        source_epoch: 7,
        descriptor_ref: String.duplicate("a", 64),
        modality: "medex:test",
        encoding: encoding,
        channels:
          for(
            i <- 1..channels,
            do: %{id: to_string(i), label: to_string(i), calibration: :unknown, unit: :unknown}
          ),
        sample_rate: {44_100, 1},
        capabilities: %{
          max_frame_samples: 32,
          max_payload_bytes: 4096,
          encodings: [encoding],
          commands: [],
          replay: :none
        }
      }

      {:ok, start} = StreamCursor.new(spec)

      final =
        Enum.reduce(0..99, start, fn sequence, cursor ->
          count = :rand.uniform(32)
          size = count * channels * StreamSpec.bytes_per_value(encoding)
          payload = :binary.copy(<<rem(sequence, 256)>>, size)

          f = %SampleFrame{
            stream_id: "w",
            source_epoch: 7,
            descriptor_ref: spec.descriptor_ref,
            sequence: sequence,
            first_sample: cursor.next_sample,
            sample_count: count,
            payload: payload,
            config_epoch: 0
          }

          assert {:ok, next, [{:append, ^f}]} = StreamCursor.plan(cursor, {:frame, f})
          assert next.next_sample == cursor.next_sample + count

          assert {:error, :stride_mismatch} =
                   SampleFrame.validate(%{f | payload: binary_part(payload, 0, size - 1)}, spec)

          next
        end)

      assert final.next_sequence == 100
    end
  end
end
