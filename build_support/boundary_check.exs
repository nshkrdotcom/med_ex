Code.require_file("module_ownership.exs", __DIR__)

defmodule MedEx.Build.Boundaries do
  @moduledoc false
  @media ~w(Elixir.Membrane Elixir.ExWebRTC Elixir.ExRTP Elixir.Phoenix Elixir.Ecto)
  @effects [
    Code,
    Port,
    File,
    File.Stream,
    Path,
    Process,
    Task,
    GenServer,
    Application,
    System,
    Agent,
    :file,
    :os,
    :timer,
    :ets,
    :dets,
    :gen_tcp,
    :gen_udp,
    :ssl,
    :socket,
    :inet,
    :inet_res,
    :httpc,
    :persistent_term,
    :rand,
    :io,
    :code,
    :disk_log,
    :mnesia,
    :rpc,
    :erpc,
    :net_kernel,
    Port,
    Node,
    Registry,
    Supervisor,
    DynamicSupervisor,
    GenEvent,
    GenServer,
    Task.Supervisor,
    System,
    :atomics,
    :counters,
    :global
  ]
  @builtins [
    :send,
    :spawn,
    :spawn_link,
    :spawn_monitor,
    :self,
    :make_ref,
    :apply,
    :exit,
    :open_port,
    :system_time,
    :monotonic_time,
    :unique_integer,
    :put,
    :get,
    :receive,
    :send_after,
    :start_timer,
    :cancel_timer,
    :process_flag,
    :process_info,
    :register,
    :unregister,
    :monitor,
    :demonitor,
    :whereis,
    :link,
    :unlink,
    :port_command,
    :port_close,
    :spawn_opt,
    :system_flag,
    :halt,
    :load_nif,
    :load_module,
    :delete_module,
    :purge_module,
    :localtime,
    :universaltime,
    :timestamp,
    :now,
    :time,
    :date,
    :node,
    :nodes,
    :garbage_collect,
    :trace,
    :trace_pattern,
    :monitor_node,
    :group_leader
  ]
  # Narrow exceptions for behaviour-selected calls. Core has no module-dispatch exceptions.
  @dispatch ~w(preview.ex preview_session.ex stream_writer.ex)
  def trace({kind, _meta, mod, fun, _arity}, env)
      when kind in [:remote_function, :remote_macro, :imported_function, :imported_macro] do
    check_edge!(env.file, mod, fun)
  end

  def trace({:struct_expansion, _, mod, _}, env), do: check_edge!(env.file, mod, :__struct__)
  def trace(_, _), do: :ok

  def check_edge!(file, mod, fun) do
    if String.contains?(file, ["/core/med_core/lib/", "/core/med_capture/lib/"]) do
      if Enum.any?(@media, &String.starts_with?(Atom.to_string(mod), &1 <> ".")),
        do: raise("external dependency in #{file}: #{mod}")

      if String.contains?(file, "/core/med_core/lib/") do
        if mod in @effects or
             (mod in [Date, Time, NaiveDateTime, DateTime] and
                fun in [:utc_today, :utc_now, :local_now, :now, :now!]) or
             (mod == :calendar and
                fun in [:local_time, :universal_time, :system_time_to_local_time]) or
             (mod in [Kernel, :erlang] and fun in @builtins) or
             (mod == IO and fun != :iodata_to_binary) or (mod == :crypto and fun != :hash),
           do: raise("core effect in #{file}: #{mod}.#{fun}")

        if String.starts_with?(Atom.to_string(mod), "Elixir.MedEx.") and
             not MapSet.member?(:persistent_term.get({__MODULE__, :core}), mod),
           do: raise("reverse dependency in #{file}: #{mod}")
      end
    end

    :ok
  end

  def ast!(file, text) do
    core? = String.contains?(file, "/core/med_core/lib/")

    Macro.prewalk(Code.string_to_quoted!(text, file: file), fn
      {name, _, args} = ast when core? and name in @builtins and is_list(args) ->
        raise "core effect in #{file}: #{elem(ast, 0)}"

      {{:., _, [receiver, method]}, meta, args} = ast when is_list(args) and is_atom(method) ->
        dynamic =
          not is_atom(receiver) and not match?({:__aliases__, _, _}, receiver) and
            not match?({:__MODULE__, _, _}, receiver)

        # A no-parentheses map/struct field access does not dispatch a module.
        if dynamic and (args != [] or not meta[:no_parens]) and
             (core? or Path.basename(file) not in @dispatch),
           do: raise("dynamic module dispatch in #{file}: #{method}")

        ast

      ast ->
        ast
    end)

    :ok
  end

  def dependencies!(app, deps) do
    expected = %{
      med_ex: [:ex_doc],
      med_core: [],
      med_capture: [:med_core],
      med_ex_opus: [
        :med_ex,
        :membrane_core,
        :membrane_raw_audio_format,
        :membrane_opus_format,
        :membrane_opus_plugin
      ],
      med_ex_rtc: [:med_ex, :ex_webrtc, :ex_rtp]
    }

    names = Enum.map(deps, &elem(&1, 0)) |> Enum.sort()

    unless names == Enum.sort(Map.fetch!(expected, app)),
      do: raise("undeclared dependency in #{app}: #{inspect(names)}")

    if app == :med_ex and not match?([{:ex_doc, _, [only: :dev, runtime: false]}], deps),
      do: raise("root tooling leaked into consumer")

    :ok
  end
end
