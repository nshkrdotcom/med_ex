defmodule MedEx.Opus.ProviderTest do
  use ExUnit.Case
  alias MedEx.Opus.Provider

  test "standalone encoder enforces owner and format and returns one real Opus packet" do
    assert {:error, :unsupported_format} =
             Provider.start_link(owner: self(), format: {250, 1, :s16le})

    assert {:ok, pid} = Provider.start_link(owner: self())
    pcm = :binary.copy(<<1, 0>>, 960)

    assert {:error, :not_owner} =
             Task.async(fn -> Provider.offer(pid, "foreign", 0, pcm) end) |> Task.await()

    assert {:error, :invalid_frame} = Provider.offer(pid, "bad", 0, <<1>>)
    assert :ok = offer(pid, pcm, System.monotonic_time(:millisecond) + 5_000)
    assert_receive {:med_ex_encoded, "op", 42, packet}, 5_000
    assert byte_size(packet) > 0
    assert :ok = Provider.stop(pid)
  end

  test "an unresponsive encoder fails its outstanding offer and retires the provider" do
    assert {:ok, pid} = Provider.start_link(owner: self())
    ready = ready(pid, System.monotonic_time(:millisecond) + 5_000)
    assert ready.ready
    :ok = :sys.suspend(ready.pipeline)
    ref = Process.monitor(pid)
    assert :ok = Provider.offer(pid, "stalled", 0, :binary.copy(<<1, 0>>, 960))
    assert_receive {:med_ex_encode_failed, "stalled", :timeout}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    refute_receive {:med_ex_encoded, "stalled", _, _}
  end

  defp ready(pid, deadline) do
    state = :sys.get_state(pid)

    if state.ready or System.monotonic_time(:millisecond) >= deadline do
      state
    else
      Process.sleep(10)
      ready(pid, deadline)
    end
  end

  defp offer(pid, bytes, deadline) do
    case Provider.offer(pid, "op", 42, bytes) do
      {:error, :busy} = busy ->
        if System.monotonic_time(:millisecond) >= deadline do
          busy
        else
          Process.sleep(10)
          offer(pid, bytes, deadline)
        end

      other ->
        other
    end
  end
end
