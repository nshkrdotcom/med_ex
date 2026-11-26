defmodule MedEx.Opus.Encoder do
  @moduledoc false
  # Owns one `opus_encoder` OS process. Frames go in via {:pcm, index, pcm};
  # the owner gets {:preview_ready, self()} after the hello and then
  # {:preview_encoded, self(), index, packet}. Dies with its port or its linker.
  use GenServer

  @hello "med_ex_opus/1 "

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  @impl true
  def init(owner) do
    exe = Path.join(:code.priv_dir(:med_ex_opus), "opus_encoder")
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, {:packet, 4}])
    {:ok, %{owner: owner, port: port, ready: false, index: nil}}
  end

  @impl true
  def handle_info({:pcm, index, pcm}, %{ready: true, index: nil} = s) do
    Port.command(s.port, pcm)
    {:noreply, %{s | index: index}}
  end

  def handle_info({port, {:data, @hello <> _}}, %{port: port, ready: false} = s) do
    send(s.owner, {:preview_ready, self()})
    {:noreply, %{s | ready: true}}
  end

  def handle_info({port, {:data, packet}}, %{port: port, ready: true, index: index} = s)
      when index != nil do
    send(s.owner, {:preview_encoded, self(), index, packet})
    {:noreply, %{s | index: nil}}
  end

  def handle_info({port, {:data, _}}, %{port: port} = s), do: {:stop, :protocol_error, s}

  def handle_info({port, {:exit_status, status}}, %{port: port} = s),
    do: {:stop, {:encoder_exit, status}, s}

  def handle_info(_, s), do: {:noreply, s}
end
