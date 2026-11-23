defmodule MedEx.Capture do
  @moduledoc "Writes indexed mono PCM16LE to a content-addressed 48 kHz WAV."
  use GenServer, restart: :temporary

  alias MedEx.Evidence
  alias MedEx.Wav

  @frame_bytes 1920
  @max_samples 48_000 * 60 * 30

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def push(pid, first_sample, pcm), do: GenServer.call(pid, {:push, first_sample, pcm})
  def subscribe(pid), do: GenServer.call(pid, {:subscribe, self()})

  def demand(pid), do: GenServer.cast(pid, {:demand, self()})

  def finish(pid), do: GenServer.call(pid, :finish, :infinity)

  @impl true
  def init(opts) do
    owner_ref = Process.monitor(Keyword.fetch!(opts, :owner))
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

  def handle_call(:finish, _from, %{count: 0} = state),
    do: {:stop, :normal, {:error, :empty_capture}, state}

  def handle_call(:finish, _from, state),
    do: {:stop, :normal, finalize(state), state}

  def handle_call({:subscribe, subscriber}, _from, state) do
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
                demand?: true
              }

            {:error, _reason} ->
              nil
          end

        preview ->
          %{preview | subscriber: subscriber, demand?: true}
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
        {:preview_ready, pipeline},
        %{preview: %{pipeline: pipeline} = preview} = state
      ),
      do: {:noreply, %{state | preview: %{preview | idle?: true}}}

  def handle_info(
        {:preview_encoded, pipeline, index, payload},
        %{preview: %{pipeline: pipeline} = preview} = state
      ) do
    send(preview.subscriber, {:med_ex_preview, self(), index, payload})
    {:noreply, %{state | preview: %{preview | idle?: true}}}
  end

  def handle_info(
        {:EXIT, supervisor, reason},
        %{preview: %{supervisor: supervisor, subscriber: subscriber}} = state
      ) do
    send(subscriber, {:med_ex_preview_failed, self(), reason})
    {:noreply, %{state | preview: nil}}
  end

  defp offer_preview(%{preview: %{idle?: true, demand?: true} = preview} = state, index, pcm)
       when byte_size(pcm) == @frame_bytes do
    send(preview.pipeline, {:pcm, index, pcm})
    %{state | preview: %{preview | idle?: false, demand?: false}}
  end

  defp offer_preview(state, _index, _pcm), do: state

  @impl true
  def terminate(_reason, state) do
    if state.preview do
      Membrane.Pipeline.terminate(state.preview.pipeline, asynchronous?: true, force?: true)
    end

    :file.close(state.fd)
    File.rm(state.temp)
    :ok
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
