defmodule MedEx.StorageConformanceTest do
  use ExUnit.Case, async: true

  alias MedEx.{SampleFrame, StreamSpec, StreamWriter}
  alias MedEx.Storage.File, as: Store

  @moduletag :tmp_dir

  defp spec do
    s = %StreamSpec{
      acquisition_id: "conf-acq",
      source_ref: "conf-dev",
      boot_id: "conf-boot",
      stream_id: "s-conf",
      source_epoch: 2,
      descriptor_ref: String.duplicate("c", 64),
      modality: "medex:ecg",
      encoding: :s16le,
      channels: [%{id: "1", label: "Lead I", calibration: :unknown, unit: :unknown}],
      sample_rate: {250, 1},
      capabilities: %{
        max_frame_samples: 8,
        max_payload_bytes: 16,
        encodings: [:s16le],
        commands: [],
        replay: :none
      }
    }

    %{s | descriptor_ref: MedEx.Serialization.descriptor_ref(s)}
  end

  defp frame(s, seq) do
    %SampleFrame{
      stream_id: s.stream_id,
      source_epoch: s.source_epoch,
      descriptor_ref: s.descriptor_ref,
      sequence: seq,
      first_sample: seq * 8,
      sample_count: 8,
      config_epoch: 1,
      payload: :binary.copy(<<seq + 1, 0>>, 8)
    }
  end

  test "unreferenced content-addressed chunk does not change sealed recovery", %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    s = spec()

    {:ok, writer} =
      StreamWriter.start_link(
        owner: self(),
        fence: "f",
        stream: s,
        artifact_dir: dir,
        limits: %{checkpoint_ms: :manual}
      )

    assert {:ok, _} = StreamWriter.push(writer, "f", frame(s, 0))
    assert {:ok, _} = StreamWriter.checkpoint(writer)
    assert {:ok, _} = StreamWriter.finish(writer)
    assert {:ok, expected} = Store.recover(dir, stream: s, fence: "f")

    # A synced content-addressed object can precede its journal append.
    orphan = :binary.copy(<<99>>, 64)
    digest = MedEx.Serialization.sha256(orphan)
    File.write!(Path.join(dir, digest <> ".pcm"), orphan)

    assert {:ok, ^expected} = Store.recover(dir, stream: s, fence: "f")
  end

  test "conformance: corrupt trailing journal bytes fail recovery instead of silent acceptance",
       %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    s = spec()

    {:ok, writer} =
      StreamWriter.start_link(
        owner: self(),
        fence: "f",
        stream: s,
        artifact_dir: dir,
        limits: %{checkpoint_ms: :manual}
      )

    assert {:ok, _} = StreamWriter.push(writer, "f", frame(s, 0))
    assert {:ok, _} = StreamWriter.checkpoint(writer)
    assert {:ok, _} = StreamWriter.finish(writer)

    journal = Path.join(dir, "stream.mejournal")
    File.write!(journal, File.read!(journal) <> <<0xFF, 0xFE, 0x00, 0x01>>)

    assert {:error, _reason} = Store.recover(dir, stream: s, fence: "f")
  end
end
