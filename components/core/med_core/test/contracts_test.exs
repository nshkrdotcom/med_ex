defmodule MedEx.ContractsTest do
  use ExUnit.Case, async: true
  alias MedEx.{MeasurementEvent, SampleFrame, StreamSpec}

  defp spec do
    %StreamSpec{
      acquisition_id: "a",
      source_ref: "device",
      boot_id: "boot",
      stream_id: "ecg",
      source_epoch: 0,
      descriptor_ref: String.duplicate("a", 64),
      modality: "medex:ecg",
      encoding: :s16le,
      sample_rate: {250, 1},
      channels: [%{id: "II", label: "Lead II", unit: "uV", calibration: :unknown}],
      capabilities: %{
        encodings: [:s16le],
        max_frame_samples: 25,
        max_payload_bytes: 64_000,
        replay: :durable_spool,
        commands: []
      }
    }
  end

  test "unknown calibration survives; invalid rates and invented units fail" do
    s = spec()
    assert :ok = StreamSpec.validate(s)
    assert {:ok, ^s} = MedEx.Serialization.stream_spec(MedEx.Serialization.to_map(s))
    assert hd(s.channels).calibration == :unknown
    assert {:error, _} = StreamSpec.validate(%{s | sample_rate: {250, 0}})
    assert {:error, _} = StreamSpec.validate(%{s | channels: [%{hd(s.channels) | unit: nil}]})
    assert {:error, _} = StreamSpec.validate(%{s | encoding: :any})
  end

  test "sample count denotes rows across channels, with exact native byte stride" do
    s = spec()
    s = %{s | channels: s.channels ++ [%{hd(s.channels) | id: "I", label: "Lead I"}]}

    f = %SampleFrame{
      stream_id: "ecg",
      source_epoch: 0,
      descriptor_ref: s.descriptor_ref,
      sequence: 0,
      first_sample: 0,
      sample_count: 2,
      config_epoch: :unknown,
      payload:
        <<-1::little-signed-16, 1::little-signed-16, 2::little-signed-16, 3::little-signed-16>>
    }

    assert :ok = SampleFrame.validate(f, s)
    assert {:error, _} = SampleFrame.validate(%{f | payload: <<0, 0, 0, 0>>}, s)
    assert {:error, _} = SampleFrame.validate(%{f | descriptor_ref: String.duplicate("b", 64)}, s)
    assert {:error, _} = SampleFrame.validate(%{f | config_epoch: 0xFFFFFFFF}, s)
  end

  test "sparse missing values are retained and floating values rejected" do
    e = %MeasurementEvent{
      event_id: "event",
      acquisition_id: "a",
      source_ref: "device",
      boot_id: "boot",
      stream_id: "oximeter",
      source_epoch: 0,
      gateway_sequence: 1,
      descriptor_ref: String.duplicate("a", 64),
      raw: {:bytes, <<1, 2>>},
      metrics: %{"spo2" => {:missing, "sensor_invalid"}}
    }

    assert :ok = MeasurementEvent.validate(e)
    assert {:ok, ^e} = MedEx.Serialization.measurement(MedEx.Serialization.to_map(e))
    statuses = %{e | device_status: %{"integer" => 7, "string" => "7", "absent" => :unknown}}

    assert {:ok, ^statuses} =
             MedEx.Serialization.measurement(MedEx.Serialization.to_map(statuses))

    assert {:error, _} =
             MeasurementEvent.validate(%{e | metrics: %{"spo2" => {:value, 97.2, 0, "%"}}})
  end

  test "an index cannot silently omit an uncovered source interval" do
    s = spec()

    segment = %MedEx.SegmentRef{
      key: "chunk",
      sha256: String.duplicate("b", 64),
      byte_size: 4,
      first_sample: 2,
      end_sample: 4,
      first_sequence: 1,
      next_sequence: 2,
      descriptor_ref: s.descriptor_ref,
      config_epoch: :unknown
    }

    index = %MedEx.StreamIndex{
      stream: s,
      segments: [segment],
      spans: [],
      terminal: :interrupted,
      journal_generation: 1,
      journal_digest: String.duplicate("c", 64),
      fence: "lease-1"
    }

    assert {:error, _} = MedEx.StreamIndex.validate(index)

    gap = %MedEx.IntegritySpan{
      stream_id: "ecg",
      source_epoch: 0,
      code: :source_gap,
      source: "device",
      first_sample: 0,
      end_sample: 2
    }

    assert :ok = MedEx.StreamIndex.validate(%{index | spans: [gap]})
    received = %{segment | first_sample: 0, end_sample: 2, first_sequence: 0, next_sequence: 1}
    assert {:error, _} = MedEx.StreamIndex.validate(%{index | segments: [received], spans: [gap]})
  end

  test "whole-frame chunks obey minimum and descriptor maximum sample cardinality" do
    s = spec()

    segment = %MedEx.SegmentRef{
      key: "chunk",
      sha256: String.duplicate("b", 64),
      byte_size: 2,
      first_sample: 0,
      end_sample: 1,
      first_sequence: 0,
      next_sequence: 2,
      descriptor_ref: s.descriptor_ref,
      config_epoch: :unknown
    }

    assert {:error, :invalid_segment} = MedEx.SegmentRef.validate(segment)
    segment = %{segment | byte_size: 52, end_sample: 26, next_sequence: 1}
    assert :ok = MedEx.SegmentRef.validate(segment)

    index = %MedEx.StreamIndex{
      stream: s,
      segments: [segment],
      spans: [],
      terminal: :finished,
      journal_generation: 1,
      journal_digest: String.duplicate("c", 64),
      fence: "lease-1"
    }

    assert {:error, :invalid_stream_index} = MedEx.StreamIndex.validate(index)
    assert :ok = MedEx.StreamIndex.validate(%{index | segments: [%{segment | next_sequence: 2}]})
  end
end
