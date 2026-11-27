#!/usr/bin/env elixir
# Second reference host for MedEx: a minimal standalone CLI recorder that
# exercises MedEx.StreamSpec, MedEx.StreamWriter (host-fenced manual checkpoints),
# and MedEx.Storage.File.recover/2 without any Fabric code.
#
# Usage: mix run tools/cli_recorder.exs <output_dir> [frame_count]

# The host owns the OS lock for the entire writable and recovery lifetime.
# The SDK does not create a second root-owner service.
defmodule MedExCLI.RootOwner do
  use GenServer
  def start_link(root), do: GenServer.start_link(__MODULE__, root, timeout: 2_000)
  @impl true
  def init(root) do
    root = Path.expand(root)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    case System.find_executable("flock") do
      nil ->
        {:stop, :flock_required}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [
              "-n",
              Path.join(root, ".capture-root.lock"),
              "sh",
              "-c",
              "printf 'locked\\n'; cat >/dev/null"
            ]
          ])

        receive do
          {^port, {:data, "locked\n"}} -> {:ok, %{root: root, token: make_ref(), port: port}}
          {^port, {:exit_status, _}} -> {:stop, :root_in_use}
        after
          1_000 ->
            Port.close(port)
            {:stop, :root_lock_timeout}
        end
    end
  end

  @impl true
  def handle_call({:med_ex_root_ownership, path}, _from, state) do
    path = Path.expand(path)

    valid =
      (path == state.root or String.starts_with?(path, state.root <> "/")) and
        not is_nil(Port.info(state.port))

    reply = if valid, do: {:ok, Map.take(state, [:root, :token])}, else: {:error, :root_not_owned}
    {:reply, reply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, %{port: port}), do: System.halt(1)
  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end
end

alias MedEx.{Receipt, SampleFrame, StreamSpec, StreamWriter}
alias MedEx.Storage.File, as: Store

{dir, count} =
  case System.argv() do
    [d] ->
      {d, 5}

    [d, n] ->
      case Integer.parse(n) do
        {count, ""} when count > 0 -> {d, count}
        _ -> raise ArgumentError, "frame_count must be a positive integer"
      end

    _ ->
      raise "Usage: mix run tools/cli_recorder.exs <output_dir> [frame_count]"
  end

{:ok, root_owner} = MedExCLI.RootOwner.start_link(dir)

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
    artifact_dir: Path.join(dir, "attempt"),
    root_owner: root_owner,
    limits: %{checkpoint_ms: :manual}
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

  {:ok, _} = StreamWriter.push(writer, fence, frame, 5_000)

  if rem(i + 1, 5) == 0 do
    {:ok, _} = StreamWriter.checkpoint(writer, fence, 5_000)
  end
end

{:ok, cp_receipt} = StreamWriter.checkpoint(writer, fence, 5_000)
true = Receipt.durable?(cp_receipt)
{:ok, terminal} = StreamWriter.finish(writer, fence, 5_000)

{:ok, recovered} =
  Store.recover(Path.join(dir, "attempt"), stream: spec, fence: fence, root_owner: root_owner)

true = Receipt.exact_prefix?(terminal.receipt, recovered.receipt)
true = recovered.sealed
true = recovered.receipt.durable_sequence == count
true = recovered.receipt.durable_sample == count * 25

expected = %{
  manifest_digest: String.duplicate("0", 64),
  index_digest: recovered.index_digest,
  stream_id: spec.stream_id,
  source_epoch: spec.source_epoch,
  descriptor_ref: spec.descriptor_ref,
  fence: fence,
  journal_id: recovered.receipt.journal_id,
  root_owner: root_owner
}

{:ok, verified_index} =
  Store.read_verified_index(Path.join(dir, "attempt"), recovered.index_digest, expected)

for segment <- recovered.index.segments do
  {:ok, bytes} = Store.read_verified_segment(verified_index, segment.first_sample, expected)
  true = byte_size(bytes) == segment.byte_size
end

IO.puts(
  "cli_recorder ok frames=#{count} cp_gen=#{cp_receipt.journal_generation} " <>
    "final_gen=#{terminal.receipt.journal_generation} sealed=#{recovered.sealed}"
)

GenServer.stop(root_owner)
