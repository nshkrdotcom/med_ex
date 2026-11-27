defmodule MedEx.Opus.ProviderLifecycleTest do
  use ExUnit.Case, async: false
  require Logger
  alias MedEx.Opus.Provider
  @moduletag :tmp_dir
  setup do
    if :os.type() == {:unix, :linux} do
      children = "/proc/#{System.pid()}/task/#{System.pid()}/children"

      assert {:ok, _} = File.read(children),
             "required Linux native cleanup proof needs readable procfs children"
    end

    :ok
  end

  defp fixture(dir, body) do
    executable = Path.join(dir, "native_fixture.py")

    File.write!(
      executable,
      ~s|#!/usr/bin/env python3\nimport os,sys,time,struct,threading,select\nopen("#{dir}/native.pid","w").write(str(os.getpid()))\ndef watch_port():\n poll=select.poll();poll.register(sys.stdout.fileno(),select.POLLERR\|select.POLLHUP)\n while True:\n  if poll.poll(100): os._exit(66)\nthreading.Thread(target=watch_port,daemon=True).start()\ndef emit(data):\n sys.stdout.buffer.write(struct.pack('>I',len(data))+data);sys.stdout.buffer.flush()\n| <>
        body
    )

    File.chmod!(executable, 0o755)
    Process.put({Provider, :executable}, executable)
    executable
  end

  defp dead_native(dir) do
    if File.exists?(Path.join(dir, "native.pid")) do
      check_native_exit(File.read!(Path.join(dir, "native.pid")))
    end
  end

  defp check_native_exit(pid) do
    if :os.type() == {:unix, :linux},
      do: assert_eventually(fn -> not File.exists?("/proc/" <> pid) end, 100)
  end

  defp assert_eventually(fun, left) do
    cond do
      fun.() ->
        :ok

      left > 0 ->
        Process.sleep(10)
        assert_eventually(fun, left - 1)

      true ->
        flunk("native process was not retired")
    end
  end

  test "public start_link has a five-second hello and six-second outer deadline", %{tmp_dir: dir} do
    fixture(dir, "time.sleep(30)\n")
    start = System.monotonic_time(:millisecond)
    assert {:error, :startup_timeout} = Provider.start_link(owner: self())
    assert System.monotonic_time(:millisecond) - start < 6500
    dead_native(dir)
  end

  test "expected startup refusal has no private crash report and preserves caller lifetime", %{
    tmp_dir: dir
  } do
    sentinel = "opus-private-startup-sentinel"
    path =
      fixture(dir, """
      while not os.path.exists('#{dir}/reject'): time.sleep(0.001)
      emit(b'wrong');time.sleep(30)
      """)
    test = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {caller, monitor} =
          spawn_monitor(fn ->
            Process.put({Provider, :executable}, path)
            send(test, {:refusal, self(), Provider.start_link(owner: self())})
            send(test, {:caller_flags, Process.info(self(), :trap_exit)})

            receive do
              :done -> :ok
            end
          end)

        assert_eventually(fn -> File.exists?(Path.join(dir, "native.pid")) end, 100)
        {:links, links} = Process.info(caller, :links)
        [initializer] = Enum.filter(links, &is_pid/1)
        send(initializer, {:private_startup_message, sentinel})
        File.write!(Path.join(dir, "reject"), "ready")
        assert_receive {:refusal, ^caller, {:error, :invalid_hello}}, 2000
        assert_receive {:caller_flags, {:trap_exit, false}}
        assert Process.alive?(caller)
        send(caller, :done)
        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
        dead_native(dir)
        Logger.warning("safe_opus_refusal_diagnostic")
      end)

    assert log =~ "safe_opus_refusal_diagnostic"
    refute log =~ sentinel
    refute log =~ "CRASH REPORT"
    refute log =~ "crasher:"
  end

  test "stop recognizes only normal dead races and never kills an unresponsive PID" do
    for {reason, expected} <- [
          {:normal, :ok},
          {:shutdown, {:error, {:outcome_unknown, :encoder_call_failed}}}
        ] do
      {pid, monitor} =
        spawn_monitor(fn ->
          receive do
            {:"$gen_call", _, :stop} -> exit(reason)
          end
        end)

      assert Provider.stop(pid) == expected
      assert_receive {:DOWN, ^monitor, :process, ^pid, ^reason}
      assert :ok = Provider.stop(pid)
    end

    test = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          {:"$gen_call", _, :stop} -> send(test, :stop_submitted)
        end

        receive do
          :done -> :ok
        end
      end)

    started = System.monotonic_time(:millisecond)
    assert {:error, {:outcome_unknown, :encoder_call_failed}} = Provider.stop(pid)
    assert System.monotonic_time(:millisecond) - started < 1500
    assert_received :stop_submitted
    assert Process.alive?(pid)
    send(pid, :done)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "expired overlapping offer preserves pending encode; idle expiry sends no bytes", %{
    tmp_dir: dir
  } do
    fixture(dir, """
    emit(b'med_ex_opus/1 fixture')
    count=0
    while True:
     header=sys.stdin.buffer.read(4)
     if len(header)!=4: break
     size=struct.unpack('>I',header)[0]
     data=sys.stdin.buffer.read(size)
     if len(data)!=size: break
     count+=1
     open('#{dir}/requests','w').write(str(count))
     while count==1 and not os.path.exists('#{dir}/release'): time.sleep(0.001)
     emit(b'encoded')
    """)

    {:ok, provider} = Provider.start_link(owner: self())
    assert provider in elem(Process.info(self(), :links), 1)
    pcm = :binary.copy(<<0>>, 1920)
    assert :ok = Provider.offer(provider, "one", 0, pcm)
    state = :sys.get_state(provider)
    expired = System.monotonic_time(:millisecond) - 1

    assert {:error, :busy} =
             GenServer.call(provider, {:offer, "two", 960, pcm, expired})

    assert :sys.get_state(provider) == state
    File.write!(Path.join(dir, "release"), "ready")
    assert_receive {:med_ex_encoded, "one", 0, "encoded"}, 1000

    assert {:error, {:not_committed, :expired}} =
             GenServer.call(provider, {:offer, "two", 960, pcm, expired})

    assert Process.alive?(provider)
    assert :sys.get_state(provider).port == state.port
    assert :ok = Provider.offer(provider, "two", 960, pcm)
    assert_receive {:med_ex_encoded, "two", 960, "encoded"}, 1000
    refute_receive {:med_ex_encoded, "one", _, _}
    refute_receive {:med_ex_encode_failed, _, _}
    assert File.read!(Path.join(dir, "requests")) == "2"
    assert :ok = Provider.stop(provider)
    dead_native(dir)
  end

  test "malformed hello, truncated header/body, early exit and missing executable are structured",
       %{tmp_dir: dir} do
    for {name, body} <- [
          {"bad", "emit(b'wrong');time.sleep(30)\n"},
          {"header", "sys.stdout.buffer.write(b'\\x00\\x00');sys.stdout.buffer.flush()\n"},
          {"body",
           "sys.stdout.buffer.write(struct.pack('>I',20)+b'short');sys.stdout.buffer.flush()\n"},
          {"exit", "sys.exit(23)\n"}
        ] do
      local = Path.join(dir, name)
      File.mkdir_p!(local)
      fixture(local, body)
      assert {:error, _} = Provider.start_link(owner: self())
      dead_native(local)
    end

    Process.put({Provider, :executable}, Path.join(dir, "missing"))
    assert {:error, :executable_unavailable} = Provider.start_link(owner: self())
    assert {:error, :invalid_owner_or_options} = Provider.start_link(owner: nil)
  end

  test "one pending offer times out, sends one failure and closes native state", %{tmp_dir: dir} do
    fixture(dir, "emit(b'med_ex_opus/1 fixture');time.sleep(30)\n")
    {:ok, provider} = Provider.start_link(owner: self())
    port = :sys.get_state(provider).port
    monitor = Process.monitor(provider)
    assert :ok = Provider.offer(provider, "one", 0, :binary.copy(<<0>>, 1920))
    assert {:error, :busy} = Provider.offer(provider, "two", 960, :binary.copy(<<0>>, 1920))
    assert_receive {:med_ex_encode_failed, "one", :encode_timeout}, 1500
    assert_receive {:DOWN, ^monitor, :process, ^provider, :normal}, 1000
    refute_receive {:med_ex_encode_failed, "one", _}
    refute_receive {:med_ex_encoded, "one", _, _}
    assert Port.info(port) == nil
    dead_native(dir)
  end

  test "empty or unsolicited output retires without a successful completion", %{tmp_dir: dir} do
    fixture(dir, "emit(b'med_ex_opus/1 fixture');time.sleep(0.1);emit(b'');time.sleep(30)\n")
    {:ok, provider} = Provider.start_link(owner: self())
    monitor = Process.monitor(provider)
    assert :ok = Provider.offer(provider, "one", 0, :binary.copy(<<0>>, 1920))
    assert_receive {:med_ex_encode_failed, "one", :protocol_error}, 1000
    assert_receive {:DOWN, ^monitor, :process, ^provider, :normal}, 1000
    dead_native(dir)
  end

  test "owner differs from caller and either lifetime retires the provider", %{tmp_dir: dir} do
    path = fixture(dir, "emit(b'med_ex_opus/1 fixture');time.sleep(30)\n")
    test = self()

    caller =
      spawn(fn ->
        Process.put({Provider, :executable}, path)
        result = Provider.start_link(owner: test)
        send(test, {:started, result})

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:started, {:ok, provider}}, 2000
    monitor = Process.monitor(provider)
    send(caller, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^provider, :normal}, 1000
    dead_native(dir)
  end

  test "outer OTP startup deadline retires a suspended initializer and its native Port", %{
    tmp_dir: dir
  } do
    path = fixture(dir, "time.sleep(30)\n")
    test = self()
    started = System.monotonic_time(:millisecond)

    caller =
      spawn(fn ->
        Process.put({Provider, :executable}, path)
        send(test, {:startup, Provider.start_link(owner: test)})
      end)

    assert_eventually(fn -> File.exists?(Path.join(dir, "native.pid")) end, 100)
    {:links, links} = Process.info(caller, :links)
    [initializer] = Enum.filter(links, &is_pid/1)
    true = :erlang.suspend_process(initializer)
    assert_receive {:startup, {:error, :timeout}}, 6500
    assert System.monotonic_time(:millisecond) - started < 7000
    refute Process.alive?(initializer)
    dead_native(dir)
  end

  test "owner death during hello and admission timeouts cannot submit a late encode", %{
    tmp_dir: dir
  } do
    path = fixture(dir, "time.sleep(30)\n")

    owner =
      spawn(fn ->
        receive do
          :done -> :ok
        end
      end)

    test = self()

    spawn(fn ->
      Process.put({Provider, :executable}, path)
      send(test, {:startup, Provider.start_link(owner: owner)})
    end)

    assert_eventually(fn -> File.exists?(Path.join(dir, "native.pid")) end, 100)
    send(owner, :done)
    assert_receive {:startup, {:error, :owner_down}}, 1000
    dead_native(dir)

    for i <- 1..3 do
      local = Path.join(dir, "timeout-#{i}")
      File.mkdir_p!(local)
      fixture(local, "emit(b'med_ex_opus/1 fixture');time.sleep(30)\n")
      {:ok, provider} = Provider.start_link(owner: self())
      port = :sys.get_state(provider).port
      :ok = :sys.suspend(provider)

      assert {:error, {:not_committed, :encoder_authorization_unavailable}} =
               Provider.offer(provider, "timeout", 0, :binary.copy(<<0>>, 1920))

      assert Process.alive?(provider)
      :ok = :sys.resume(provider)
      refute_receive {:med_ex_encoded, "timeout", _, _}
      assert :sys.get_state(provider).pending == nil
      assert :ok = Provider.stop(provider)
      assert Port.info(port) == nil
      dead_native(local)
    end
  end
end
