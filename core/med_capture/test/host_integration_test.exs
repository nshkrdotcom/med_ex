defmodule MedEx.HostIntegrationTest do
  use ExUnit.Case, async: true

  alias MedEx.{SampleFrame, StreamSpec, StreamWriter}
  alias MedEx.Storage.File, as: Store

  @moduletag :tmp_dir

  defp spec do
    s = %StreamSpec{
      acquisition_id: "host-acq",
      source_ref: "host-dev",
      boot_id: "host-boot",
      stream_id: "s1",
      source_epoch: 1,
      descriptor_ref: String.duplicate("b", 64),
      modality: "medex:ecg",
      encoding: :s16le,
      channels: [%{id: "1", label: "Lead I", calibration: :unknown, unit: :unknown}],
      sample_rate: {250, 1},
      capabilities: %{
        max_frame_samples: 10,
        max_payload_bytes: 20,
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
      first_sample: seq * 10,
      sample_count: 10,
      config_epoch: 1,
      payload: :binary.copy(<<seq + 1, 0>>, 10)
    }
  end

  test "a DynamicSupervisor-hosted writer enforces owner and fence, checkpoints manually, and seals",
       %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    s = spec()

    {:ok, writer} =
      DynamicSupervisor.start_child(
        sup,
        {StreamWriter,
         owner: self(), fence: "f1", stream: s, artifact_dir: dir, checkpoint_ms: :manual}
      )

    # Non-owner is rejected
    assert {:error, :not_owner} =
             Task.async(fn -> StreamWriter.push(writer, "f1", frame(s, 0)) end) |> Task.await()

    # Stale fence is rejected
    assert {:error, _} = StreamWriter.push(writer, "wrong-fence", frame(s, 0))

    assert {:ok, _} = StreamWriter.push(writer, "f1", frame(s, 0))
    assert {:ok, cp} = StreamWriter.checkpoint(writer)
    assert cp.journal_generation >= 1

    assert {:ok, _} = StreamWriter.finish(writer)
    assert {:ok, recovered} = Store.recover(dir, stream: s, fence: "f1")
    assert recovered.sealed
    assert recovered.terminal_recorded
  end

  test "second reference host (tools/cli_recorder.exs) records, seals, and recovers", %{
    tmp_dir: dir
  } do
    on_exit(fn -> File.rm_rf!(dir) end)
    script = Path.expand("../../../tools/cli_recorder.exs", __DIR__)
    assert File.regular?(script)

    {out, 0} =
      System.cmd("mix", ["run", script, dir, "4"],
        cd: Path.expand("../../..", __DIR__),
        stderr_to_stdout: true
      )

    assert out =~ "cli_recorder ok frames=4"
    assert out =~ "sealed=true"
  end
end
