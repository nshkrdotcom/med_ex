defmodule ExternalDeviceDriverTest do
  use ExUnit.Case

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  alias MedEx.{StreamWriter, SampleFrame, StreamSpec}
  @tag :tmp_dir
  test "public root owns contracts, assets and raw recording", %{tmp_dir: dir} do
    assert Application.get_application(StreamSpec) == :med_ex
    assert MedEx.Contract.api_revision() == 1
    assert File.regular?(MedEx.Web.asset_path("pcm_worklet.js"))
    deps = Map.keys(Mix.Project.deps_paths())
    for forbidden <- [:med_core, :med_capture, :med_rtc, :weld], do: refute(forbidden in deps)
    profile = System.fetch_env!("SDK_PROFILE")
    assert :ex_webrtc in deps == profile in ["rtc", "both"]
    assert :membrane_opus_plugin in deps == profile in ["opus", "both"]

    for {name, rate} <- [{"ecg", 250}, {"diagnostic_audio", 48_000}] do
      spec = %StreamSpec{
        acquisition_id: "a",
        source_ref: "driver",
        boot_id: "boot",
        stream_id: name,
        source_epoch: 0,
        descriptor_ref: String.duplicate("0", 64),
        modality: "medex:" <> name,
        channels: [%{id: "one", label: "1", unit: :unknown, calibration: :unknown}],
        encoding: :s16le,
        sample_rate: {rate, 1},
        capabilities: %{
          encodings: [:s16le],
          max_frame_samples: 2,
          max_payload_bytes: 4,
          replay: :none,
          commands: []
        }
      }

      spec = %{spec | descriptor_ref: MedEx.Serialization.descriptor_ref(spec)}

      frame = %SampleFrame{
        stream_id: name,
        source_epoch: 0,
        descriptor_ref: spec.descriptor_ref,
        sequence: 0,
        first_sample: 0,
        sample_count: 2,
        config_epoch: :unknown,
        payload: <<7, 0, 9, 0>>
      }

      path = Path.join(dir, name)

      assert {:ok, w} =
               StreamWriter.start_link(
                 owner: self(),
                 stream: spec,
                 artifact_dir: path,
                 fence: "f"
               )

      assert {:ok, _} = StreamWriter.push(w, frame)
      assert {:ok, %{segments: [chunk]}} = StreamWriter.finish(w)
      assert MedEx.Storage.File.read_segment(path, chunk) == {:ok, frame.payload}
    end
  end
end
