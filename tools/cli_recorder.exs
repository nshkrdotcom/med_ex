#!/usr/bin/env elixir
# Second reference host for MedEx: a minimal standalone CLI recorder that
# exercises MedEx.StreamSpec, MedEx.StreamWriter (host-fenced manual checkpoints),
# and MedEx.Storage.File.recover/2 without any Fabric code.
#
# Usage: mix run tools/cli_recorder.exs <output_dir> [frame_count]

alias MedEx.{SampleFrame, StreamSpec, StreamWriter}
alias MedEx.Storage.File, as: Store

{dir, count} =
  case System.argv() do
    [d] -> {d, 5}
    [d, n] -> {d, String.to_integer(n)}
    _ -> raise "Usage: mix run tools/cli_recorder.exs <output_dir> [frame_count]"
  end

File.mkdir_p!(dir)

spec = %StreamSpec{
  acquisition_id: "cli-acq-1",
  source_ref: "cli-dev-1",
  boot_id: "cli-boot-1",
  stream_id: "waveform-1",
  source_epoch: 0,
  descriptor_ref: String.duplicate("a", 64),
  modality: "medex:ecg",
  encoding: :s16le,
  channels: [%{id: "ch1", label: "Lead I", calibration: :unknown, unit: :unknown}],
  sample_rate: {250, 1},
  capabilities: %{
    max_frame_samples: 25,
    max_payload_bytes: 50,
    encodings: [:s16le],
    commands: [],
    replay: :none
  }
}

spec = %{spec | descriptor_ref: MedEx.Serialization.descriptor_ref(spec)}

fence = "cli-fence-1"

{:ok, writer} =
  StreamWriter.start_link(
    owner: self(),
    fence: fence,
    stream: spec,
    artifact_dir: dir,
    checkpoint_ms: :manual
  )

for i <- 0..(count - 1) do
  pcm = :binary.copy(<<rem(i + 1, 127), 0>>, 25)

  frame = %SampleFrame{
    stream_id: spec.stream_id,
    source_epoch: spec.source_epoch,
    descriptor_ref: spec.descriptor_ref,
    sequence: i,
    first_sample: i * 25,
    sample_count: 25,
    config_epoch: 1,
    payload: pcm
  }

  {:ok, _} = StreamWriter.push(writer, fence, frame)
end

{:ok, cp_receipt} = StreamWriter.checkpoint(writer)
{:ok, final_receipt} = StreamWriter.finish(writer)
{:ok, recovered} = Store.recover(dir, stream: spec, fence: fence)

IO.puts(
  "cli_recorder ok frames=#{count} cp_gen=#{cp_receipt.journal_generation} " <>
    "final_gen=#{final_receipt.journal_generation} sealed=#{recovered.sealed}"
)
