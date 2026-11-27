defmodule MedEx.Opus.ProviderTest do
  use ExUnit.Case, async: false
  alias MedEx.Opus.Provider
  @moduletag :tmp_dir
  defp pcm,
    do: for(i <- 0..959, into: <<>>, do: <<round(12_000 * :math.sin(i / 20))::little-signed-16>>)

  test "supported concrete exports and dependency closure remain independent" do
    internal =
      GenServer.behaviour_info(:callbacks) ++
        [child_spec: 1, module_info: 0, module_info: 1, __info__: 1]

    assert Enum.sort(Provider.__info__(:functions) -- internal) ==
             Enum.sort(start_link: 1, offer: 4, stop: 1)

    deps = Mix.Project.config()[:deps] |> Enum.map(&elem(&1, 0))
    refute :med_ex in deps
    refute :med_ex_rtc in deps
  end

  test "concrete owner API encodes one pinned-libopus packet and denies unrelated callers" do
    assert {:error, :invalid_owner_or_options} =
             Provider.start_link(owner: self(), format: :other)

    assert {:ok, pid} = Provider.start_link(owner: self())

    assert {:error, :not_owner} =
             Task.async(fn -> Provider.offer(pid, "foreign", 0, pcm()) end) |> Task.await()

    assert {:error, :not_owner} = Task.async(fn -> Provider.stop(pid) end) |> Task.await()
    assert {:error, :invalid_frame} = Provider.offer(pid, "bad", 0, <<1>>)
    assert {:error, :invalid_frame} = Provider.offer(pid, :unbounded_atom, 0, pcm())
    assert :ok = Provider.offer(pid, "op", 9_007_199_254_740_993, pcm())
    assert_receive {:med_ex_encoded, "op", 9_007_199_254_740_993, packet}, 2000
    assert byte_size(packet) in 1..1275
    assert :ok = Provider.stop(pid)
    assert :ok = Provider.stop(pid)
  end

  test "real pinned decoder verifies non-silent 960-sample signal", %{tmp_dir: dir} do
    decoder = Path.join(dir, "decode")
    project = Mix.Project.deps_paths()[:med_ex_opus] || File.cwd!()
    app = to_string(:code.lib_dir(:med_ex_opus))

    {log, status} =
      System.cmd(
        "make",
        [
          "-C",
          project,
          "test-decoder",
          "MIX_APP_PATH=#{app}",
          "DECODER=#{decoder}",
          "DECODER_SRC=#{Path.join(__DIR__, "decode.c")}"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, log
    {:ok, pid} = Provider.start_link(owner: self())
    assert :ok = Provider.offer(pid, "tone", 0, pcm())
    assert_receive {:med_ex_encoded, "tone", 0, packet}, 2000
    file = Path.join(dir, "packet")
    File.write!(file, packet)
    assert {"", 0} = System.cmd(decoder, [file])
    assert :ok = Provider.stop(pid)
  end

  test "owner death closes the one provider Port", %{tmp_dir: _} do
    test = self()

    owner =
      spawn(fn ->
        {:ok, pid} = Provider.start_link(owner: self())
        send(test, {:provider, pid, :sys.get_state(pid).port})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:provider, pid, port}, 6000
    monitor = Process.monitor(pid)
    send(owner, :done)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2000
    assert Port.info(port) == nil
  end
end
