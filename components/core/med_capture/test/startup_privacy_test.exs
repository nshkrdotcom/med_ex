defmodule MedEx.StartupPrivacyTest do
  use ExUnit.Case, async: false
  require Logger
  alias MedEx.CaptureFixture, as: F
  alias MedEx.StreamWriter

  setup do
    fixture = F.root()
    on_exit(fn -> F.cleanup(fixture) end)
    fixture
  end

  test "expected startup refusal cleans storage and omits a queued private message", f do
    test = self()
    sentinel = "writer-private-startup-sentinel"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {caller, ref} = spawn_monitor(fn -> refused_start(f, test, sentinel) end)

        assert_receive {:refusal, ^caller, {:error, {:not_committed, :startup_refused}}}, 2000
        assert_receive {:caller_flags, {:trap_exit, false}}
        assert Process.alive?(caller)
        send(caller, :done)
        assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
        Logger.warning("safe_writer_refusal_diagnostic")
      end)

    assert log =~ "safe_writer_refusal_diagnostic"
    refute log =~ sentinel
    refute log =~ "CRASH REPORT"
    refute log =~ "crasher:"
    refute F.recover(f) == {:error, :writer_active}
    assert File.read!(Path.join(f.dir, "stream.mejournal")) == ""
  end

  defp refused_start(fixture, test, sentinel) do
    Process.put({StreamWriter, :fault_hook}, fn
      :before_journal_append ->
        send(self(), {:private_startup_message, sentinel})
        {:error, :startup_refused}

      _ ->
        :ok
    end)

    send(test, {:refusal, self(), F.start(fixture)})
    send(test, {:caller_flags, Process.info(self(), :trap_exit)})

    receive do
      :done -> :ok
    end
  end
end
