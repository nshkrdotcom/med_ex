defmodule ExternalDeviceDriverTest do
  use ExUnit.Case
  alias Mix.Dep.Lock

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  test "ordinary Mix owns exactly the selected independent applications" do
    profile = System.fetch_env!("SDK_PROFILE")
    transport = System.fetch_env!("SDK_TRANSPORT")
    source = System.fetch_env!("SDK_SOURCE_ROOT")
    dependency_projects = Mix.Project.deps_paths()
    deps = Map.keys(dependency_projects)
    base? = profile in ["base", "both"]
    assert :med_ex in deps == base?
    opus? = profile in ["opus", "both"]
    rtc? = profile in ["rtc", "both"]

    assert :med_ex_opus in deps == opus?
    assert :elixir_make in deps == opus?
    refute :membrane_core in deps
    assert :med_ex_rtc in deps == rtc?
    assert :ex_webrtc in deps == rtc?

    forbidden = [
      :med_core,
      :med_capture,
      :med_rtc,
      :med_ex_maintainer,
      :weld,
      :mix_workspace_ops
    ]

    for app <- forbidden, do: refute(app in deps)

    apps =
      if(base?, do: [:med_ex], else: []) ++
        if(opus?, do: [:med_ex_opus], else: []) ++ if(rtc?, do: [:med_ex_rtc], else: [])

    started = MapSet.new(Application.started_applications(), &elem(&1, 0))

    modules =
      for app <- apps, into: %{} do
        assert MapSet.member?(started, app)

        source_dir =
          if app == :med_ex, do: source, else: Path.join([source, "extensions", to_string(app)])

        version = source_dir |> Path.join("VERSION") |> File.read!() |> String.trim()
        assert to_string(Application.spec(app, :vsn)) == version
        owned = Application.spec(app, :modules)
        assert is_list(owned) and owned != []

        for module <- owned do
          assert Application.get_application(module) == app

          if transport in ["full", "prepared", "tracked", "archive", "registry"] do
            project = dependency_projects |> Map.fetch!(app) |> Path.expand()
            compiled_from = module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
            assert String.starts_with?(Path.expand(compiled_from), project <> "/")
          end
        end

        {app, Enum.sort(owned)}
      end

    implemented = modules |> Map.values() |> List.flatten()
    assert implemented == Enum.uniq(implemented)
    if base?, do: assert(MedEx.Receipt in modules.med_ex)
    if opus?, do: assert(MedEx.Opus.Provider in modules.med_ex_opus)
    if rtc?, do: assert(MedEx.RTC.Provider in modules.med_ex_rtc)

    if evidence = System.get_env("SDK_EFFECTIVE_INPUTS") do
      File.write!(evidence, JSON.encode!(effective_inputs(modules, dependency_projects, source)))
    end

    File.write!(
      System.fetch_env!("SDK_MODULE_INVENTORY"),
      JSON.encode!(Map.new(modules, fn {app, owned} -> {app, Enum.map(owned, &to_string/1)} end))
    )
  end

  defp effective_inputs(modules, paths, source) do
    lock = Lock.read()

    for {app, {:git, _url, revision, _opts}} <- Map.take(lock, Map.keys(modules)) do
      assert {^revision, 0} =
               subprocess_head(Map.fetch!(paths, app))
    end

    sdk =
      Map.new(modules, fn {app, owned} ->
        executable =
          Map.new(owned, fn module ->
            path = :code.which(module)
            {:ok, {^module, md5}} = :beam_lib.md5(path)
            metadata = module.module_info(:compile)

            {inspect(module),
             [
               Base.encode16(md5, case: :lower),
               hash(File.read!(metadata[:source])),
               hash(:erlang.term_to_binary(metadata[:options], [:deterministic]))
             ]}
          end)

        specification =
          app
          |> Application.spec()
          |> Keyword.drop([:description, :id])
          |> Enum.sort()

        {app, %{beams: executable, application: hash(:erlang.term_to_binary(specification))}}
      end)

    test_inputs =
      for app <- Map.keys(modules) -- [:med_ex],
          file <- Path.wildcard(Path.join([source, "extensions", to_string(app), "test", "**/*"])),
          File.regular?(file),
          do: {Path.relative_to(file, source), hash(File.read!(file))}

    native =
      if Map.has_key?(modules, :med_ex_opus) do
        project = Map.fetch!(paths, :med_ex_opus)

        sources =
          for pattern <- ["Makefile", "c_src/**/*"],
              file <- Path.wildcard(Path.join(project, pattern)),
              File.regular?(file),
              into: %{},
              do: {Path.relative_to(file, project), hash(File.read!(file))}

        encoder = Path.join(:code.priv_dir(:med_ex_opus), "opus_encoder")
        Map.put(sources, "priv/opus_encoder", hash(File.read!(encoder)))
      else
        %{}
      end

    %{
      sdk: sdk,
      native: native,
      provider_tests: Enum.sort(test_inputs) |> Map.new(),
      dependency_lock:
        hash(:erlang.term_to_binary(Map.drop(lock, Map.keys(modules)), [:deterministic])),
      compiler_env: Mix.env(),
      compiler_target: Mix.target()
    }
  end

  defp subprocess_head(path) do
    {output, status} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    {String.trim(output), status}
  end

  defp hash(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @tag :tmp_dir
  test "CLI reference host records against the selected external SDK", %{tmp_dir: dir} do
    if System.fetch_env!("SDK_PROFILE") in ["base", "both"] do
      # The standalone host script is copied beside the consumer, never loaded
      # as product source or from a checkout-relative runtime dependency.
      script = Path.join(__DIR__, "cli_recorder.exs")

      {output, status} =
        System.cmd("mix", ["run", "--no-compile", "--no-deps-check", script, dir, "4"],
          env: [{"MIX_ENV", to_string(Mix.env())}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "cli_recorder ok frames=4"
      assert output =~ "sealed=true"
    end
  end
end
