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
    assert :ok = Provider.offer(pid, "op", 42, pcm)
    assert_receive {:med_ex_encoded, "op", 42, packet}, 5_000
    assert byte_size(packet) > 0
    assert :ok = Provider.stop(pid)
  end

  test "an unresponsive encoder fails its outstanding offer and retires the provider" do
    assert {:ok, pid} = Provider.start_link(owner: self())
    %{encoder: encoder} = :sys.get_state(pid)
    :ok = :sys.suspend(encoder)
    ref = Process.monitor(pid)
    assert :ok = Provider.offer(pid, "stalled", 0, :binary.copy(<<1, 0>>, 960))
    assert_receive {:med_ex_encode_failed, "stalled", :timeout}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    refute_receive {:med_ex_encoded, "stalled", _, _}
  end

  test "normal owner exit retires the provider and closes the native port" do
    test = self()

    owner =
      spawn(fn ->
        {:ok, provider} = Provider.start_link(owner: self())
        send(test, {:provider, provider})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:provider, provider}, 6_000
    %{encoder: encoder} = :sys.get_state(provider)
    %{port: port} = :sys.get_state(encoder)
    provider_ref = Process.monitor(provider)
    encoder_ref = Process.monitor(encoder)
    send(owner, :done)
    assert_receive {:DOWN, ^provider_ref, :process, ^provider, :normal}, 2_000
    assert_receive {:DOWN, ^encoder_ref, :process, ^encoder, _}, 2_000
    assert Port.info(port) == nil
  end

  test "stopping with a pending offer sends one failure and closes the encoder" do
    assert {:ok, provider} = Provider.start_link(owner: self())
    %{encoder: encoder} = :sys.get_state(provider)
    %{port: port} = :sys.get_state(encoder)
    ref = Process.monitor(encoder)
    :ok = :sys.suspend(encoder)
    assert :ok = Provider.offer(provider, :pending, 0, :binary.copy(<<0>>, 1920))
    assert :ok = Provider.stop(provider)
    assert_receive {:med_ex_encode_failed, :pending, :encoder_stopped}
    assert_receive {:DOWN, ^ref, :process, ^encoder, _}, 2_000
    assert Port.info(port) == nil
    refute_receive {:med_ex_encode_failed, :pending, _}
    refute_receive {:med_ex_encoded, :pending, _, _}
  end
end
