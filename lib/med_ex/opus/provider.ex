defmodule MedEx.Opus.Provider do
  @moduledoc """
  One in-flight 20 ms mono PCM16LE offer to a libopus encoder OS process. Startup
  and stop wait at most five seconds. A pending encode has a one-second
  deadline; timeout reports failure and retires that provider, so uncertain late
  output cannot be assigned to a subsequent offer. Native failure isolation
  still requires a separate BEAM OS process in the strict host profile.
  """
  use GenServer, restart: :temporary
  @behaviour MedEx.PreviewProvider
  @start_timeout 5_000
  @encode_timeout 1_000
  @impl MedEx.PreviewProvider
  def start_legacy(owner) do
    with {:ok, encoder} <- MedEx.Opus.Encoder.start_link(owner), do: {:ok, encoder, encoder}
  end

  @impl MedEx.PreviewProvider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, timeout: @start_timeout)
  @impl MedEx.PreviewProvider
  def offer(pid, operation, index, pcm) do
    GenServer.call(pid, {:offer, operation, index, pcm}, @encode_timeout)
  catch
    :exit, {:timeout, _} -> {:error, {:outcome_unknown, :timeout}}
    :exit, {reason, _} -> {:error, {:outcome_unknown, reason}}
  end

  @impl MedEx.PreviewProvider
  def stop(pid), do: GenServer.stop(pid, :normal, @start_timeout)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)

    case Keyword.get(opts, :format, {48_000, 1, :s16le}) do
      {48_000, 1, :s16le} ->
        case start_legacy(self()) do
          {:ok, supervisor, pipeline} ->
            {:ok,
             %{
               owner: owner,
               monitor: Process.monitor(owner),
               supervisor: supervisor,
               supervisor_ref: Process.monitor(supervisor),
               pipeline: pipeline,
               ready: false,
               pending: nil
             }}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :unsupported_format}
    end
  end

  @impl GenServer
  def handle_call({:offer, _, _, _}, {caller, _}, %{owner: owner} = s) when caller != owner,
    do: {:reply, {:error, :not_owner}, s}

  def handle_call({:offer, id, index, pcm}, _, %{ready: true, pending: nil} = s)
      when is_integer(index) and index >= 0 and is_binary(pcm) and byte_size(pcm) == 1_920 do
    send(s.pipeline, {:pcm, index, pcm})
    token = make_ref()
    timer = Process.send_after(self(), {:encode_timeout, token}, @encode_timeout)
    {:reply, :ok, %{s | pending: {id, index, token, timer}}}
  end

  def handle_call({:offer, _, index, pcm}, _, s)
      when not is_integer(index) or index < 0 or not is_binary(pcm) or byte_size(pcm) != 1920,
      do: {:reply, {:error, :invalid_frame}, s}

  def handle_call({:offer, _, _, _}, _, s), do: {:reply, {:error, :busy}, s}

  @impl GenServer
  def handle_info({:preview_ready, pid}, %{pipeline: pid} = s), do: {:noreply, %{s | ready: true}}

  def handle_info(
        {:preview_encoded, pid, index, data},
        %{pipeline: pid, pending: {op, index, _, timer}} = s
      ) do
    Process.cancel_timer(timer)
    send(s.owner, {:med_ex_encoded, op, index, data})
    {:noreply, %{s | pending: nil}}
  end

  def handle_info({:encode_timeout, token}, %{pending: {op, _, token, _}} = s) do
    send(s.owner, {:med_ex_encode_failed, op, :timeout})
    # Retire this pipeline. Its unknown late output must not be attributed to a
    # later offer, even when the caller reuses a sample index or operation ID.
    {:stop, :normal, %{s | pending: nil}}
  end

  def handle_info({:encode_timeout, _}, s), do: {:noreply, s}
  def handle_info({:EXIT, sup, reason}, %{supervisor: sup} = s), do: encoder_down(s, reason)

  def handle_info({:DOWN, ref, :process, _, reason}, %{supervisor_ref: ref} = s),
    do: encoder_down(s, reason)

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  defp encoder_down(s, reason) do
    if s.pending do
      {op, _, _, _} = s.pending
      send(s.owner, {:med_ex_encode_failed, op, reason})
    end

    {:stop, :normal, %{s | pending: nil}}
  end

  @impl GenServer
  def terminate(_, s) do
    if s.pending do
      {id, _, _, _} = s.pending
      send(s.owner, {:med_ex_encode_failed, id, :encoder_stopped})
    end

    Process.exit(s.supervisor, :shutdown)
    :ok
  end
end
