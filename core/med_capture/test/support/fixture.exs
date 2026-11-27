defmodule MedEx.TestRootOwner do
  use GenServer
  def start_link(root), do: GenServer.start_link(__MODULE__, root)

  def init(root) do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    executable =
      System.find_executable("flock") || raise "Linux flock is required for storage conformance"

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, 1024},
        args: [
          "--exclusive",
          "--nonblock",
          Path.join(root, ".root.lock"),
          "sh",
          "-c",
          "printf 'locked\\n'; cat >/dev/null"
        ]
      ])

    receive do
      {^port, {:data, {:eol, "locked"}}} -> {:ok, %{root: root, port: port, token: make_ref()}}
      {^port, {:exit_status, _}} -> {:stop, :root_in_use}
    after
      2_000 ->
        Port.close(port)
        {:stop, :root_lock_timeout}
    end
  end

  def handle_call({:med_ex_root_ownership, path}, _, state) do
    if Port.info(state.port) != nil and
         (path == state.root or String.starts_with?(path, state.root <> "/")),
       do: {:reply, {:ok, Map.take(state, [:root, :token])}, state},
       else: {:reply, {:error, :unowned_path}, state}
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state), do: {:stop, :normal, state}
  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end
end

defmodule MedEx.CaptureFixture do
  alias MedEx.{SampleFrame, Serialization, StreamSpec, StreamWriter}
  alias MedEx.Storage.File, as: Store

  def root do
    base = Path.expand("../../../../_build/test/med_ex_artifacts", __DIR__)
    root = Path.join(base, Integer.to_string(System.unique_integer([:positive, :monotonic])))
    {:ok, owner} = MedEx.TestRootOwner.start_link(root)
    Process.unlink(owner)
    %{root: root, root_owner: owner, dir: Path.join(root, "attempt"), spec: spec()}
  end

  def cleanup(fixture) do
    if Process.alive?(fixture.root_owner), do: GenServer.stop(fixture.root_owner)
    File.rm_rf!(fixture.root)
  end

  def spec do
    spec = %StreamSpec{
      acquisition_id: "acquisition",
      source_ref: "source",
      boot_id: "boot",
      stream_id: "audio",
      source_epoch: 0,
      descriptor_ref: String.duplicate("0", 64),
      modality: "medex:audio",
      encoding: :s16le,
      sample_rate: {48_000, 1},
      channels: [%{id: "mono", label: "Mono", unit: :unknown, calibration: :unknown}],
      capabilities: %{
        encodings: [:s16le],
        max_frame_samples: 960,
        max_payload_bytes: 1920,
        commands: [],
        replay: :durable_spool
      }
    }

    %{spec | descriptor_ref: Serialization.descriptor_ref(spec)}
  end

  def frame(sequence, sample \\ nil, config \\ 0) do
    spec = spec()

    %SampleFrame{
      stream_id: spec.stream_id,
      source_epoch: spec.source_epoch,
      descriptor_ref: spec.descriptor_ref,
      sequence: sequence,
      first_sample: sample || sequence * 960,
      sample_count: 960,
      config_epoch: config,
      payload: :binary.copy(<<rem(sequence, 256), 0>>, 960)
    }
  end

  def opts(f, extra \\ []),
    do:
      Keyword.merge(
        [
          owner: self(),
          stream: f.spec,
          fence: "f1",
          artifact_dir: f.dir,
          root_owner: f.root_owner,
          limits: %{checkpoint_ms: :manual}
        ],
        extra
      )

  def start(f, extra \\ []), do: StreamWriter.start_link(opts(f, extra))

  def recover(f, extra \\ []),
    do:
      Store.recover(
        f.dir,
        Keyword.merge(
          [stream: f.spec, fence: "f1", root_owner: f.root_owner],
          extra
        )
      )

  def expected(prefix, manifest \\ String.duplicate("a", 64)) do
    %{
      root_owner: prefix.provenance.root_owner,
      manifest_digest: manifest,
      index_digest: prefix.index_digest,
      stream_id: prefix.stream.stream_id,
      source_epoch: prefix.stream.source_epoch,
      descriptor_ref: prefix.stream.descriptor_ref,
      fence: prefix.fence,
      journal_id: prefix.receipt.journal_id
    }
  end

  def verified(prefix) do
    Store.read_verified_index(prefix.artifact_dir, prefix.index_digest, expected(prefix))
  end

  def retire(pid) do
    Process.unlink(pid)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      2_000 -> raise "writer did not retire"
    end
  end
end
