defmodule MedEx.Opus.Encoder do
  @moduledoc false
  # Owns one `opus_encoder` OS process. Frames go in via {:pcm, index, pcm};
  # the owner gets {:preview_ready, self()} after the hello and then
  # {:preview_encoded, self(), index, packet}. Dies with its port or its linker.
  use GenServer

  @hello "med_ex_opus/1 "
  @start_timeout 5_000

  def start_link(owner) do
    exe = Path.join(:code.priv_dir(:med_ex_opus), "opus_encoder")
    GenServer.start_link(__MODULE__, {owner, exe}, timeout: @start_timeout)
  end

  @impl true
  def init({owner, exe}) do
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, {:packet, 4}])

    receive do
      {^port, {:data, @hello <> version}} when byte_size(version) > 0 ->
        send(owner, {:preview_ready, self()})
        {:ok, %{owner: owner, port: port, index: nil}}

      {^port, {:exit_status, status}} ->
        {:error, {:encoder_exit, status}}

      {^port, {:data, _}} ->
        {:error, :protocol_error}
    after
      @start_timeout -> {:error, :startup_timeout}
    end
  end

  @impl true
  def handle_info({:pcm, index, pcm}, %{index: nil} = s) do
    Port.command(s.port, pcm)
    {:noreply, %{s | index: index}}
  end

  def handle_info({port, {:data, packet}}, %{port: port, index: index} = s)
      when index != nil and byte_size(packet) in 1..1275 do
    send(s.owner, {:preview_encoded, self(), index, packet})
    {:noreply, %{s | index: nil}}
  end

  def handle_info({port, {:data, _}}, %{port: port} = s), do: {:stop, :protocol_error, s}

  def handle_info({port, {:exit_status, status}}, %{port: port} = s),
    do: {:stop, {:encoder_exit, status}, s}

  def handle_info(_, s), do: {:noreply, s}
end
