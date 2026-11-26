defmodule MedEx.Opus.EncoderTest do
  use ExUnit.Case, async: true

  alias MedEx.Opus.Encoder

  @moduletag :tmp_dir

  test "startup fails within its deadline when a native process never sends hello", %{
    tmp_dir: dir
  } do
    executable = executable(dir, "cat >/dev/null")

    assert {:error, :startup_timeout} =
             GenServer.start(Encoder, {self(), executable}, timeout: 6_000)

    refute_receive {:preview_ready, _}
  end

  test "startup rejects an invalid hello before publishing readiness", %{tmp_dir: dir} do
    executable = executable(dir, "printf '\\000\\000\\000\\003bad'\ncat >/dev/null")
    assert {:error, :protocol_error} = GenServer.start(Encoder, {self(), executable})
    refute_receive {:preview_ready, _}
  end

  test "native exit during startup is reported without publishing readiness", %{tmp_dir: dir} do
    executable = executable(dir, "exit 23")
    assert {:error, {:encoder_exit, 23}} = GenServer.start(Encoder, {self(), executable})
    refute_receive {:preview_ready, _}
  end

  @tag capture_log: true
  test "an empty native reply fails the protocol instead of completing an offer", %{tmp_dir: dir} do
    executable =
      executable(dir, """
      printf '\\000\\000\\000\\022med_ex_opus/1 test'
      dd bs=1 count=1924 of=/dev/null 2>/dev/null
      printf '\\000\\000\\000\\000'
      cat >/dev/null
      """)

    assert {:ok, encoder} = GenServer.start(Encoder, {self(), executable})
    assert_receive {:preview_ready, ^encoder}
    ref = Process.monitor(encoder)
    send(encoder, {:pcm, 0, :binary.copy(<<0>>, 1920)})
    assert_receive {:DOWN, ^ref, :process, ^encoder, :protocol_error}, 2_000
    refute_receive {:preview_encoded, ^encoder, _, _}
  end

  test "normal encoder shutdown closes its real native port" do
    assert {:ok, encoder} = Encoder.start_link(self())
    assert_receive {:preview_ready, ^encoder}
    %{port: port} = :sys.get_state(encoder)
    assert Port.info(port) != nil
    assert :ok = GenServer.stop(encoder)
    assert Port.info(port) == nil
  end

  defp executable(dir, body) do
    path = Path.join(dir, "encoder")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end
end
