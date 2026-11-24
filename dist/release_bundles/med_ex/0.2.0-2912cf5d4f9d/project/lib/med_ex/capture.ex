defmodule MedEx.Capture do
  @moduledoc """
  GenServer that writes indexed mono 48 kHz PCM16LE audio to an immutable,
  content-addressed WAV file and fans full frames out to a bounded live Opus
  preview branch.

  ## Lifecycle & Ownership

  The host starts each capture under its own `DynamicSupervisor` (this module
  uses `restart: :temporary` and registers no global names). Capture monitors
  the `:owner` producer process and stops, removing its temporary `.part` file,
  if `:owner` exits before `finish/1` succeeds. Only this PID may call
  `push/3` and `finish/1`. Other callers receive `{:error, :not_owner}`.

  ## Preview Messages

  A preview peer owner calls `subscribe/1` (single active subscriber; a newer
  subscriber replaces the previous one) and receives:

    * `{:med_ex_preview, capture_pid, sample_index, opus_payload}` — one
      encoded 20 ms Opus packet. After sending it with `MedEx.Preview.send_opus/4`,
      call `demand/1` to request the next packet.
    * `{:med_ex_preview_replaced, capture_pid}` — sent to the displaced listener
      when a different process subscribes.
    * `{:med_ex_preview_failed, capture_pid, reason}` — sent if the internal
      Opus encoder exits. Capture itself continues uninterrupted and a new
      subscriber can re-subscribe.
  """
  use GenServer, restart: :temporary

  alias MedEx.Evidence
  alias MedEx.Wav

  @frame_bytes 1920
  @max_samples 48_000 * 60 * 30

  @doc """
  Starts a capture process linked to the caller (typically a host `DynamicSupervisor`).

  ## Required options

    * `:owner` — PID of the single PCM producer process. Capture monitors this
      PID and aborts if it exits before `finish/1`.
    * `:acquisition_id` — host-assigned string identifying this acquisition.
    * `:artifact_dir` — existing directory where the temporary `.part` file and
      final `<file_sha256>.wav` artifact are written.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Appends one contiguous mono 48 kHz PCM16LE chunk at `first_sample`.

  Chunks must start at sample `0`, advance contiguously without gaps, contain
  an even number of bytes in `2..1920` (up to 960 samples / 20 ms), stay within
  the 30-minute maximum (`86_400_000` samples), and send at most one short tail
  frame (`< 1920` bytes) immediately before `finish/1`.

  A non-owner receives `{:error, :not_owner}` and recording continues.
  For the producer, returns `:ok`, or `{:error, :invalid_frame | File.posix()}` (stopping the
  capture process and discarding the temporary file).
  """
  @spec push(GenServer.server(), non_neg_integer(), binary()) :: :ok | {:error, term()}
  def push(pid, first_sample, pcm), do: GenServer.call(pid, {:push, first_sample, pcm})

  @doc """
  Subscribes the calling process to bounded live Opus preview frames.

  Only one preview subscriber is active at a time; subscribing from a new
  process replaces the previous subscriber. Returns `:ok` or
  `{:error, :preview_unavailable}`.
  """
  @spec subscribe(GenServer.server()) :: :ok | {:error, :preview_unavailable}
  def subscribe(pid), do: GenServer.call(pid, :subscribe)

  @doc """
  Signals readiness for the next `{:med_ex_preview, ...}` packet from the
  active preview subscriber.
  """
  @spec demand(GenServer.server()) :: :ok
  def demand(pid), do: GenServer.cast(pid, {:demand, self()})

  @doc """
  Flushes and fsyncs the WAV header, installs the content-addressed
  `<file_sha256>.wav` file, fsyncs `:artifact_dir`, and stops the capture.

  Returns `{:ok, %MedEx.Evidence{}}`, `{:error, :empty_capture}` if no samples
  were pushed, `{:error, :artifact_conflict}` if a conflicting file already
  exists at the target digest path, or `{:error, reason}` on filesystem failure.
  """
  @spec finish(GenServer.server()) :: {:ok, Evidence.t()} | {:error, term()}
  def finish(pid), do: GenServer.call(pid, :finish, :infinity)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    owner_ref = Process.monitor(owner)
    dir = Keyword.fetch!(opts, :artifact_dir)
    acquisition_id = Keyword.fetch!(opts, :acquisition_id)
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    temp = Path.join(dir, ".capture-#{suffix}.part")

    Process.flag(:trap_exit, true)

    case :file.open(temp, [:write, :binary, :raw, :exclusive]) do
      {:ok, fd} ->
        case :file.write(fd, Wav.header(0, 48_000)) do
          :ok ->
            {:ok,
             %{
               owner: owner,
               owner_ref: owner_ref,
               fd: fd,
               temp: temp,
               dir: dir,
               acquisition_id: acquisition_id,
               count: 0,
               tail?: false,
               preview: nil,
               pcm_hash: :crypto.hash_init(:sha256)
             }}

          {:error, reason} ->
            :file.close(fd)
            File.rm(temp)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:push, _, _}, {caller, _}, %{owner: owner} = state) when caller != owner,
    do: {:reply, {:error, :not_owner}, state}

  def handle_call({:push, index, pcm}, _from, %{count: index, tail?: false} = state)
      when is_binary(pcm) and byte_size(pcm) in 2..@frame_bytes and
             rem(byte_size(pcm), 2) == 0 and index + div(byte_size(pcm), 2) <= @max_samples do
    case :file.write(state.fd, pcm) do
      :ok ->
        state = offer_preview(state, index, pcm)

        {:reply, :ok,
         %{
           state
           | count: index + div(byte_size(pcm), 2),
             tail?: byte_size(pcm) < @frame_bytes,
             pcm_hash: :crypto.hash_update(state.pcm_hash, pcm)
         }}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:push, _, _}, _from, state),
    do: {:stop, :normal, {:error, :invalid_frame}, state}

  def handle_call(:finish, {caller, _}, %{owner: owner} = state) when caller != owner,
    do: {:reply, {:error, :not_owner}, state}

  def handle_call(:finish, _from, %{count: 0} = state),
    do: {:stop, :normal, {:error, :empty_capture}, state}

  def handle_call(:finish, _from, state),
    do: {:stop, :normal, finalize(state), state}

  def handle_call(:subscribe, {subscriber, _}, %{preview: %{subscriber: subscriber}} = state),
    do: {:reply, :ok, state}

  def handle_call(:subscribe, {subscriber, _}, state) do
    preview =
      case state.preview do
        nil ->
          case Membrane.Pipeline.start_link(MedEx.PreviewEncoder, self()) do
            {:ok, supervisor, pipeline} ->
              %{
                supervisor: supervisor,
                pipeline: pipeline,
                idle?: false,
                subscriber: subscriber,
                subscriber_ref: Process.monitor(subscriber),
                demand?: true
              }

            {:error, _reason} ->
              nil
          end

        preview ->
          send(preview.subscriber, {:med_ex_preview_replaced, self()})
          Process.demonitor(preview.subscriber_ref, [:flush])

          %{
            preview
            | subscriber: subscriber,
              subscriber_ref: Process.monitor(subscriber),
              demand?: true
          }
      end

    {:reply, if(preview, do: :ok, else: {:error, :preview_unavailable}),
     %{state | preview: preview}}
  end

  @impl true
  def handle_cast({:demand, subscriber}, %{preview: %{subscriber: subscriber} = preview} = state),
    do: {:noreply, %{state | preview: %{preview | demand?: true}}}

  def handle_cast({:demand, _subscriber}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{preview: %{subscriber_ref: ref} = preview} = state
      ) do
    stop_preview(preview)
    {:noreply, %{state | preview: nil}}
  end

  def handle_info(
        {:preview_ready, pipeline},
        %{preview: %{pipeline: pipeline} = preview} = state
      ),
      do: {:noreply, %{state | preview: %{preview | idle?: true}}}

  def handle_info(
        {:preview_encoded, pipeline, index, payload},
        %{preview: %{pipeline: pipeline} = preview} = state
      ) do
    send(preview.subscriber, {:med_ex_preview, self(), index, payload})
    {:noreply, %{state | preview: %{preview | idle?: true, demand?: false}}}
  end

  def handle_info(
        {:EXIT, supervisor, reason},
        %{preview: %{supervisor: supervisor, subscriber: subscriber, subscriber_ref: ref}} = state
      ) do
    Process.demonitor(ref, [:flush])
    send(subscriber, {:med_ex_preview_failed, self(), reason})
    {:noreply, %{state | preview: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp offer_preview(%{preview: %{idle?: true, demand?: true} = preview} = state, index, pcm)
       when byte_size(pcm) == @frame_bytes do
    send(preview.pipeline, {:pcm, index, pcm})
    %{state | preview: %{preview | idle?: false, demand?: false}}
  end

  defp offer_preview(state, _index, _pcm), do: state

  @impl true
  def terminate(_reason, state) do
    if state.preview, do: stop_preview(state.preview)

    :file.close(state.fd)
    File.rm(state.temp)
    :ok
  end

  defp stop_preview(preview) do
    Membrane.Pipeline.terminate(preview.pipeline, asynchronous?: true, force?: true)
  end

  defp finalize(state) do
    with :ok <- :file.pwrite(state.fd, 0, Wav.header(state.count * 2, 48_000)),
         :ok <- :file.sync(state.fd),
         digest <- digest_file(state.temp),
         key = digest <> ".wav",
         :ok <- install(state.temp, Path.join(state.dir, key), digest),
         :ok <- Wav.sync_directory(state.dir) do
      {:ok,
       %Evidence{
         acquisition_id: state.acquisition_id,
         artifact_key: key,
         file_sha256: digest,
         pcm_sha256: hex(:crypto.hash_final(state.pcm_hash)),
         end_sample: state.count,
         sample_count: state.count
       }}
    end
  rescue
    error in File.Error -> {:error, error.reason}
  end

  defp install(temp, path, digest) do
    case File.ln(temp, path) do
      {:error, :eexist} ->
        if digest_file(path) == digest, do: :ok, else: {:error, :artifact_conflict}

      result ->
        result
    end
  end

  defp digest_file(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> hex()
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
