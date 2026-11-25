Code.require_file("module_ownership.exs", __DIR__)

defmodule MedEx.Build.Boundaries do
  @moduledoc false
  alias MedEx.Build.Ownership

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
    Node,
    Registry,
    Supervisor,
    DynamicSupervisor,
    GenEvent,
    Task.Supervisor,
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
  @dispatch ~w(med_ex/preview.ex med_ex/preview_session.ex med_ex/stream_writer.ex)

  def configure(roots, core_modules) do
    :persistent_term.put(__MODULE__, {roots, MapSet.new(core_modules)})
  end

  def clear, do: :persistent_term.erase(__MODULE__)

  def trace({kind, _meta, mod, fun, _arity}, env)
      when kind in [:remote_function, :remote_macro, :imported_function, :imported_macro] do
    check_edge!(env.file, mod, fun)
  end

  def trace({:struct_expansion, _, mod, _}, env), do: check_edge!(env.file, mod, :__struct__)
  def trace(_, _), do: :ok

  def check_edge!(file, mod, fun) do
    {roots, core_modules} = :persistent_term.get(__MODULE__)

    with {owner, _} <- Ownership.source_owner(file, roots) do
      name = Atom.to_string(mod)

      if Enum.any?(@media, &(name == &1 or String.starts_with?(name, &1 <> "."))),
        do: raise("external dependency in #{file}: #{mod}")

      if owner == :med_core do
        if mod in @effects or
             (mod in [Date, Time, NaiveDateTime, DateTime] and
                fun in [:utc_today, :utc_now, :local_now, :now, :now!]) or
             (mod == :calendar and
                fun in [:local_time, :universal_time, :system_time_to_local_time]) or
             (mod in [Kernel, :erlang] and fun in @builtins) or
             (mod == IO and fun != :iodata_to_binary) or (mod == :crypto and fun != :hash),
           do: raise("core effect in #{file}: #{mod}.#{fun}")

        if String.starts_with?(Atom.to_string(mod), "Elixir.MedEx.") and
             not MapSet.member?(core_modules, mod),
           do: raise("reverse dependency in #{file}: #{mod}")
      end
    end

    :ok
  end

  def ast!(file, text) do
    {roots, _} = :persistent_term.get(__MODULE__)
    {owner, relative} = Ownership.source_owner(file, roots)
    core? = owner == :med_core

    Macro.prewalk(Code.string_to_quoted!(text, file: file), fn
      {name, _, args} = ast when core? and name in @builtins and is_list(args) ->
        raise "core effect in #{file}: #{elem(ast, 0)}"

      {{:., _, [receiver, method]}, meta, args} = ast when is_list(args) and is_atom(method) ->
        dynamic =
          not is_atom(receiver) and not match?({:__aliases__, _, _}, receiver) and
            not match?({:__MODULE__, _, _}, receiver)

        # A no-parentheses map/struct field access does not dispatch a module.
        if dynamic and (args != [] or not meta[:no_parens]) and
             (core? or relative not in @dispatch),
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
        :membrane_opus_plugin,
        :credo,
        :dialyxir,
        :ex_doc
      ],
      med_ex_rtc: [:med_ex, :ex_webrtc, :ex_rtp, :credo, :dialyxir, :ex_doc]
    }

    names = Enum.map(deps, &elem(&1, 0)) |> Enum.sort()

    unless names == Enum.sort(Map.fetch!(expected, app)),
      do: raise("undeclared dependency in #{app}: #{inspect(names)}")

    for tool <- [:credo, :dialyxir], tool in names do
      {^tool, _, opts} = List.keyfind(deps, tool, 0)

      unless opts[:runtime] == false and
               Enum.sort(List.wrap(opts[:only])) in [[:dev], [:dev, :test]],
             do: raise("development tooling leaked into #{app} consumer")
    end

    if :ex_doc in names do
      unless match?({:ex_doc, _, [only: :dev, runtime: false]}, List.keyfind(deps, :ex_doc, 0)),
        do: raise("documentation tooling leaked into #{app} consumer")
    end

    :ok
  end
end
