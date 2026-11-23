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

  alias MedEx.Capture.FrameRules
  alias MedEx.{Evidence, PreviewSession, Wav}

  @preview_start_timeout 5_000
  @subscribe_timeout @preview_start_timeout + 1_000

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

  Only one preview subscriber is active at a time. A new subscriber replaces
  the previous one. Returns `:ok` when the encoder is ready or
  `{:error, :preview_unavailable}` if startup fails or is cancelled. Capture
  allows five seconds for startup. The caller also cancels its subscription if
  Capture has not replied within six seconds. Recording continues during startup.
  """
  @spec subscribe(GenServer.server()) :: :ok | {:error, :preview_unavailable}
  def subscribe(pid) do
    deadline = System.monotonic_time(:millisecond) + @subscribe_timeout
    GenServer.call(pid, {:subscribe, deadline}, @subscribe_timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _}} ->
      # Same-sender ordering puts cancellation after the request, even when
      # Capture was busy for the entire call, and before this caller can retry.
      GenServer.cast(pid, {:cancel_preview, self()})
      {:error, :preview_unavailable}
  end

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

    # Supervisor shutdown must run terminate/2 to remove unfinished evidence.
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
               start_preview_encoder:
                 Keyword.get(opts, :start_preview_encoder, &PreviewSession.start_encoder/0),
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

  def handle_call({:push, index, pcm}, _from, state) do
    with {:ok, count, tail?} <- FrameRules.advance(state.count, state.tail?, index, pcm),
         :ok <- :file.write(state.fd, pcm) do
      state = if tail?, do: state, else: offer_preview(state, index, pcm)

      {:reply, :ok,
       %{state | count: count, tail?: tail?, pcm_hash: :crypto.hash_update(state.pcm_hash, pcm)}}
    else
      :error -> {:stop, :normal, {:error, :invalid_frame}, state}
      {:error, reason} -> {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call(:finish, {caller, _}, %{owner: owner} = state) when caller != owner,
    do: {:reply, {:error, :not_owner}, state}

  def handle_call(:finish, _from, %{count: 0} = state),
    do: {:stop, :normal, {:error, :empty_capture}, state}

  def handle_call(:finish, _from, state),
    do: {:stop, :normal, finalize(state), state}

  def handle_call({:subscribe, deadline}, {subscriber, _} = from, state) do
    # Monotonic clock origins are local to each VM. A request that already
    # expired in this VM must not displace a healthy listener after a long write.
    if node(subscriber) == node() and System.monotonic_time(:millisecond) >= deadline do
      {:reply, {:error, :preview_unavailable}, state}
    else
      subscribe_preview(from, state)
    end
  end

  @impl true
  def handle_cast(
        {:demand, subscriber},
        %{preview: %{subscriber: subscriber, phase: :awaiting_demand}} = state
      ),
      do: {:noreply, put_in(state.preview.phase, :ready)}

  def handle_cast({:demand, _subscriber}, state), do: {:noreply, state}

  def handle_cast({:cancel_preview, subscriber}, %{preview: %{subscriber: subscriber}} = state) do
    stop_preview(state.preview)
    {:noreply, %{state | preview: nil}}
  end

  def handle_cast({:cancel_preview, _subscriber}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{preview: %{subscriber_ref: ref}} = state) do
    stop_preview(state.preview)
    {:noreply, %{state | preview: nil}}
  end

  def handle_info(
        {:preview_ready, session},
        %{preview: %{session: session, phase: {:starting, waiting, timer}}} = state
      ) do
    reply_subscribers(waiting, timer, :ok)
    {:noreply, put_in(state.preview.phase, :ready)}
  end

  def handle_info(
        {:preview_start_timeout, session},
        %{preview: %{session: session, phase: {:starting, _, _}}} = state
      ) do
    stop_preview(state.preview)
    {:noreply, %{state | preview: nil}}
  end

  def handle_info(
        {:preview_encoded, session, index, payload},
        %{preview: %{session: session, phase: {:encoding, index}}} = state
      ) do
    send(state.preview.subscriber, {:med_ex_preview, self(), index, payload})
    {:noreply, put_in(state.preview.phase, :awaiting_demand)}
  end

  def handle_info({:EXIT, session, reason}, %{preview: %{session: session} = preview} = state) do
    Process.demonitor(preview.subscriber_ref, [:flush])

    case preview.phase do
      {:starting, waiting, timer} ->
        reply_subscribers(waiting, timer, {:error, :preview_unavailable})

      _active ->
        send(preview.subscriber, {:med_ex_preview_failed, self(), reason})
    end

    {:noreply, %{state | preview: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp subscribe_preview({subscriber, _} = from, %{preview: %{subscriber: subscriber}} = state) do
    case state.preview.phase do
      {:starting, waiting, timer} ->
        {:noreply, put_in(state.preview.phase, {:starting, [from | waiting], timer})}

      _active ->
        {:reply, :ok, state}
    end
  end

  defp subscribe_preview({subscriber, _} = from, state) do
    if previous = state.preview do
      stop_preview(previous)
      send(previous.subscriber, {:med_ex_preview_replaced, self()})
    end

    session = PreviewSession.start_link(self(), state.start_preview_encoder)
    timer = Process.send_after(self(), {:preview_start_timeout, session}, @preview_start_timeout)

    preview = %{
      session: session,
      subscriber: subscriber,
      subscriber_ref: Process.monitor(subscriber),
      phase: {:starting, [from], timer}
    }

    {:noreply, %{state | preview: preview}}
  end

  defp offer_preview(%{preview: %{phase: :ready, session: session}} = state, index, pcm) do
    send(session, {:pcm, index, pcm})
    put_in(state.preview.phase, {:encoding, index})
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
    Process.exit(preview.session, :shutdown)
    Process.demonitor(preview.subscriber_ref, [:flush])

    case preview.phase do
      {:starting, waiting, timer} ->
        reply_subscribers(waiting, timer, {:error, :preview_unavailable})

      _active ->
        :ok
    end
  end

  defp reply_subscribers(waiting, timer, result) do
    Process.cancel_timer(timer)
    Enum.each(waiting, &GenServer.reply(&1, result))
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
