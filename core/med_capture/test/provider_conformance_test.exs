defmodule MedEx.ProviderConformanceTest do
  use ExUnit.Case, async: true

  defmodule FakePreviewProvider do
    @behaviour MedEx.PreviewProvider
    use GenServer

    @impl true
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def offer(pid, op, index, pcm), do: GenServer.call(pid, {:offer, op, index, pcm})

    @impl true
    def stop(pid), do: GenServer.stop(pid, :normal)

    @impl GenServer
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner)}}

    @impl GenServer
    def handle_call({:offer, _, _, _}, {caller, _}, %{owner: owner} = s) when caller != owner,
      do: {:reply, {:error, :not_owner}, s}

    def handle_call({:offer, op, index, pcm}, _, s) when byte_size(pcm) == 1_920 do
      send(s.owner, {:med_ex_encoded, op, index, <<1, 2, 3>>})
      {:reply, :ok, s}
    end

    def handle_call({:offer, _, _, _}, _, s), do: {:reply, {:error, :invalid_frame}, s}
  end

  defmodule FakeRTCProvider do
    @behaviour MedEx.RTCProvider

    @impl true
    def answer(sdp, _opts) when is_binary(sdp), do: {:ok, :fake_peer, "v=0\r\n"}

    @impl true
    def send_opus(:fake_peer, packet, ts, dur)
        when is_binary(packet) and is_integer(ts) and is_integer(dur),
        do: :ok

    @impl true
    def close(:fake_peer), do: :ok
  end

  test "PreviewProvider behaviour contract enforces owner, frame size, and encoded reply" do
    {:ok, pid} = FakePreviewProvider.start_link(owner: self())

    assert {:error, :not_owner} =
             Task.async(fn ->
               FakePreviewProvider.offer(pid, :op, 0, :binary.copy(<<0>>, 1920))
             end)
             |> Task.await()

    assert {:error, :invalid_frame} = FakePreviewProvider.offer(pid, :op, 0, <<1, 2>>)
    assert :ok = FakePreviewProvider.offer(pid, :op, 42, :binary.copy(<<0>>, 1920))
    assert_receive {:med_ex_encoded, :op, 42, <<1, 2, 3>>}
    assert :ok = FakePreviewProvider.stop(pid)
  end

  test "RTCProvider behaviour contract supports answer, send_opus, and close" do
    assert {:ok, peer, answer_sdp} = FakeRTCProvider.answer("v=0\r\n", [])
    assert is_binary(answer_sdp)
    assert :ok = FakeRTCProvider.send_opus(peer, <<1, 2, 3>>, 0, 960)
    assert :ok = FakeRTCProvider.close(peer)
  end
end
