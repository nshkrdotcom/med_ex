defmodule MedEx.Opus.Provider do
  @moduledoc """
  One explicit owner, GenServer and native Port. Offers are 960 mono 48 kHz
  signed PCM16LE samples (1920 bytes). One accepted request is pending at a time;
  `:ok` acknowledges admission, not encoding. The owner receives
  `{:med_ex_encoded, operation_id, source_sample, packet}` or
  `{:med_ex_encode_failed, operation_id, reason}`. A failed/uncertain pipeline is
  retired. Operation IDs are bounded strings unique within the host peer session.
  Startup hello is bounded at 5 seconds with a 6-second outer OTP deadline.
  """
  use GenServer, restart: :temporary
  @hello_timeout 5_000
  @start_timeout 6_000
  @encode_timeout 1_000
  @call_timeout 1_000
  @hello "med_ex_opus/1 "

  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) == [:owner] and
         is_pid(opts[:owner]) and node(opts[:owner]) == node() and Process.alive?(opts[:owner]) do
      executable =
        if Code.ensure_loaded?(ExUnit), do: Process.get({__MODULE__, :executable}), else: nil

      executable =
        executable || Path.join(to_string(:code.priv_dir(:med_ex_opus)), "opus_encoder")

      initial = %{
        owner: opts[:owner],
        caller: self(),
        executable: executable,
        deadline: now() + @hello_timeout
      }

      case GenServer.start_link(__MODULE__, initial, timeout: @start_timeout) do
        {:error, {:shutdown, reason}} -> {:error, reason}
        result -> result
      end
    else
      {:error, :invalid_owner_or_options}
    end
  end

  def start_link(_), do: {:error, :invalid_owner_or_options}

  def offer(pid, id, sample, pcm) when is_pid(pid) do
    if operation_id?(id) and is_integer(sample) and sample in 0..0xFFFFFFFFFFFFFFFF and
         is_binary(pcm) and byte_size(pcm) == 1920 do
      owned_call(pid, fn deadline -> {:offer, id, sample, pcm, deadline} end)
    else
      {:error, :invalid_frame}
    end
  end

  def offer(_, _, _, _), do: {:error, :invalid_frame}

  def stop(pid) when is_pid(pid) and node(pid) == node() do
    # The live server checks ownership atomically with stop. Unlike an offer,
    # this call needs no authorization round trip and may never kill a PID on
    # timeout: the caller has no proof that an unresponsive process admitted it.
    GenServer.call(pid, :stop, @call_timeout)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] ->
      if Process.alive?(pid),
        do: {:error, {:outcome_unknown, :encoder_call_failed}},
        else: :ok

    :exit, _ ->
      {:error, {:outcome_unknown, :encoder_call_failed}}
  end

  def stop(_), do: {:error, :invalid_encoder}

  defp owned_call(pid, message) do
    deadline = now() + @call_timeout

    case authorize(pid) do
      :ok ->
        remaining = deadline - now()

        if remaining > 0,
          do: submitted_call(pid, message.(deadline), remaining),
          else: {:error, {:not_committed, :expired}}

      {:error, _} = error ->
        error

      _ ->
        {:error, {:not_committed, :invalid_encoder_authorization}}
    end
  end

  defp authorize(pid) do
    GenServer.call(pid, :authorize, @call_timeout)
  catch
    :exit, _ -> {:error, {:not_committed, :encoder_authorization_unavailable}}
  end

  defp submitted_call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, _ ->
      retire(pid)
      {:error, {:outcome_unknown, :encoder_call_failed}}
  end

  @impl true
  def init(initial) do
    case initialize(initial) do
      {:stop, reason} ->
        # Failed startup must return the refusal without sending the caller an exit.
        Process.unlink(initial.caller)
        {:stop, {:shutdown, reason}}

      success ->
        success
    end
  end

  defp initialize(initial) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(initial.owner)
    caller_ref = Process.monitor(initial.caller)

    with true <-
           now() < initial.deadline and Process.alive?(initial.owner) and
             Process.alive?(initial.caller),
         {:ok, port} <- open_port(initial.executable) do
      result = await_hello(port, initial, owner_ref, caller_ref)

      case result do
        :ok ->
          {:ok,
           %{
             owner: initial.owner,
             owner_ref: owner_ref,
             caller: initial.caller,
             caller_ref: caller_ref,
             port: port,
             pending: nil,
             used: MapSet.new()
           }}

        {:error, reason} ->
          close_port(port)
          {:stop, reason}
      end
    else
      false -> {:stop, :startup_abandoned}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp open_port(executable) do
    {:ok, Port.open({:spawn_executable, executable}, [:binary, :exit_status, {:packet, 4}])}
  rescue
    _ in [ArgumentError, ErlangError] -> {:error, :executable_unavailable}
  end

  defp await_hello(port, initial, owner_ref, caller_ref) do
    remaining = max(initial.deadline - now(), 0)

    receive do
      {^port, {:data, @hello <> version}} when byte_size(version) in 1..48 ->
        if String.valid?(version) and Regex.match?(~r/\A[A-Za-z0-9 ._+-]+\z/, version) and
             now() < initial.deadline and Process.alive?(initial.owner) and
             Process.alive?(initial.caller), do: :ok, else: {:error, :invalid_hello}

      {^port, {:data, _}} ->
        {:error, :invalid_hello}

      {^port, {:exit_status, status}} ->
        {:error, {:encoder_exit, status}}

      {:EXIT, ^port, _} ->
        {:error, :encoder_exit}

      {:DOWN, ^owner_ref, :process, _, _} ->
        {:error, :owner_down}

      {:DOWN, ^caller_ref, :process, _, _} ->
        {:error, :startup_abandoned}

      {:EXIT, caller, _} when caller == initial.caller ->
        {:error, :startup_abandoned}
    after
      remaining -> {:error, :startup_timeout}
    end
  end

  @impl true
  def handle_call(_, {caller, _}, s) when caller != s.owner, do: {:reply, {:error, :not_owner}, s}
  def handle_call(:authorize, _, s), do: {:reply, :ok, s}
  def handle_call(:stop, _, s), do: {:stop, :normal, :ok, fail_pending(s, :encoder_stopped)}

  def handle_call({:offer, id, sample, pcm, deadline}, _, s) do
    cond do
      not operation_id?(id) or not is_integer(sample) or sample < 0 or sample > 0xFFFFFFFFFFFFFFFF or
        not is_binary(pcm) or byte_size(pcm) != 1920 ->
        {:reply, {:error, :invalid_frame}, s}

      not is_nil(s.pending) ->
        {:reply, {:error, :busy}, s}

      not is_integer(deadline) or now() >= deadline ->
        {:reply, {:error, {:not_committed, :expired}}, s}

      MapSet.member?(s.used, id) ->
        {:reply, {:error, :operation_id_reused}, s}

      MapSet.size(s.used) >= 100_000 ->
        {:stop, :normal, {:error, :operation_limit}, s}

      true ->
        case command(s.port, pcm) do
          :ok ->
            token = make_ref()
            timer = Process.send_after(self(), {:encode_timeout, token}, @encode_timeout)

            pending = %{
              id: id,
              sample: sample,
              token: token,
              timer: timer,
              deadline: now() + @encode_timeout
            }

            {:reply, :ok, %{s | pending: pending, used: MapSet.put(s.used, id)}}

          {:error, reason} ->
            {:stop, :normal, {:error, {:outcome_unknown, reason}}, s}
        end
    end
  end

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_operation}, s}

  @impl true
  def handle_info({port, {:data, packet}}, %{port: port, pending: pending} = s)
      when is_map(pending) and byte_size(packet) in 1..1275 do
    if now() < pending.deadline and Process.alive?(s.owner) do
      Process.cancel_timer(pending.timer)
      send(s.owner, {:med_ex_encoded, pending.id, pending.sample, packet})
      {:noreply, %{s | pending: nil}}
    else
      {:stop, :normal, fail_pending(s, :encode_timeout)}
    end
  end

  def handle_info({port, {:data, _}}, %{port: port} = s),
    do: {:stop, :normal, fail_pending(s, :protocol_error)}

  def handle_info({:encode_timeout, token}, %{pending: %{token: token}} = s),
    do: {:stop, :normal, fail_pending(s, :encode_timeout)}

  def handle_info({:encode_timeout, _}, s), do: {:noreply, s}

  def handle_info({port, {:exit_status, _}}, %{port: port} = s),
    do: {:stop, :normal, fail_pending(s, :encoder_exit)}

  def handle_info({:EXIT, port, _}, %{port: port} = s),
    do: {:stop, :normal, fail_pending(s, :encoder_exit)}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = s),
    do: {:stop, :normal, fail_pending(s, :owner_down)}

  def handle_info({:DOWN, ref, :process, _, _}, %{caller_ref: ref} = s),
    do: {:stop, :normal, fail_pending(s, :caller_down)}

  def handle_info({:EXIT, caller, _}, %{caller: caller} = s),
    do: {:stop, :normal, fail_pending(s, :caller_down)}

  def handle_info(_, s), do: {:stop, :normal, fail_pending(s, :unexpected_message)}

  defp fail_pending(%{pending: nil} = s, _), do: s

  defp fail_pending(s, reason) do
    Process.cancel_timer(s.pending.timer)
    if Process.alive?(s.owner), do: send(s.owner, {:med_ex_encode_failed, s.pending.id, reason})
    %{s | pending: nil}
  end

  @impl true
  def terminate(_, s) do
    fail_pending(s, :encoder_stopped)
    close_port(s.port)
  end

  defp command(port, pcm) do
    if Port.command(port, pcm), do: :ok, else: {:error, :port_closed}
  rescue
    _ in [ArgumentError, ErlangError] -> {:error, :port_closed}
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ in [ArgumentError, ErlangError] -> :ok
  end

  defp retire(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  defp operation_id?(id),
    do: is_binary(id) and byte_size(id) in 1..96 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  defp now, do: System.monotonic_time(:millisecond)
end
