Code.require_file("../../build_support/boundary_check.exs", __DIR__)

defmodule MedEx.ArchitectureTest do
  use ExUnit.Case, async: false

  alias MedEx.Build.{Boundaries, Ownership}

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    on_exit(&Boundaries.clear/0)
    :ok
  end

  @fixture_path "/fixture/pure/negative.ex"

  test "negative fixtures fail for their own boundary" do
    Boundaries.configure([med_core: Path.dirname(@fixture_path)], [MedEx.StreamSpec])

    assert :ok ==
             Boundaries.check_edge!("/outside/owned/roots.ex", File, :read!)

    assert_raise RuntimeError, ~r/reverse dependency/, fn ->
      Boundaries.check_edge!(@fixture_path, MedEx.StreamWriter, :push)
    end

    assert_raise RuntimeError, ~r/core effect/, fn ->
      Boundaries.check_edge!(@fixture_path, File, :read!)
    end

    assert_raise RuntimeError, ~r/core effect/, fn ->
      Boundaries.check_edge!(@fixture_path, Code, :eval_string)
    end

    assert_raise RuntimeError, ~r/core effect/, fn ->
      Boundaries.check_edge!(@fixture_path, :erlang, :send_after)
    end

    for {mod, fun} <- [
          {DateTime, :utc_now},
          {:calendar, :local_time},
          {:io, :put_chars},
          {:code, :load_binary},
          {:erlang, :load_nif},
          {Port, :command}
        ] do
      assert_raise RuntimeError, ~r/core effect/, fn ->
        Boundaries.check_edge!(@fixture_path, mod, fun)
      end
    end

    assert_raise RuntimeError, ~r/external dependency/, fn ->
      Boundaries.check_edge!(@fixture_path, ExWebRTC.PeerConnection, :__struct__)
    end

    assert_raise RuntimeError, ~r/dynamic module/, fn ->
      Boundaries.ast!(@fixture_path, "def read(mod, arg), do: mod.read(arg)")
    end

    assert_raise RuntimeError, ~r/core effect/, fn ->
      Boundaries.ast!(@fixture_path, "def get(mod), do: apply(mod, :get, [])")
    end

    assert_raise RuntimeError, ~r/duplicate module/, fn ->
      Ownership.combine!([%{MedEx.StreamSpec => "a"}, %{MedEx.StreamSpec => "b"}])
    end

    assert_raise RuntimeError, ~r/undeclared dependency/, fn ->
      Boundaries.dependencies!(:med_core, [{:ex_webrtc, ">= 0.0.0"}])
    end
  end

  @tag :tmp_dir
  test "real compiler trace rejects a reverse edge and aliased effect", %{tmp_dir: dir} do
    lib = Path.join(dir, "pure_source")
    out = Path.join(dir, "ebin")
    File.mkdir_p!(lib)
    File.mkdir!(out)
    Boundaries.configure([med_core: lib], [MedEx.StreamSpec])
    previous = Code.compiler_options()

    try do
      Code.compiler_options(tracers: [Boundaries])

      for {body, reason} <- [
            {"def bad(pid), do: MedEx.StreamWriter.receipt(pid, \"fence\", 5000)",
             "reverse dependency"},
            {"alias File, as: NoEffects; def bad(p), do: NoEffects.read(p)", "core effect"},
            {"def bad(pid), do: :erlang.send_after(5, pid, :ping)", "core effect"}
          ] do
        file = Path.join(lib, "bad.ex")
        File.write!(file, "defmodule BoundaryViolationFixture do\n#{body}\nend\n")

        assert {:error, errors, _} =
                 Kernel.ParallelCompiler.compile_to_path([file], out, return_diagnostics: true)

        assert inspect(errors) =~ reason
      end
    after
      Code.compiler_options(tracers: previous.tracers)
    end
  end

  test "direct Mix and Weld use the same component declaration and package inputs" do
    cfg = Mix.Project.config()
    {composition, _binding} = Code.eval_file("build_support/composition.exs")
    {manifest, _binding} = Code.eval_file("build_support/weld.exs")
    artifacts = manifest[:artifacts]

    assert cfg[:app] == :med_ex
    assert cfg[:elixirc_paths] == Enum.map(composition.components, &Path.join(&1, "lib"))
    assert cfg[:test_paths] == ["test" | Enum.map(composition.components, &Path.join(&1, "test"))]
    assert :ok == Boundaries.dependencies!(:med_ex, cfg[:deps], :workspace)

    assert Keyword.keys(artifacts) == [:med_ex]
    manifest_base = artifacts[:med_ex]
    assert manifest[:schema] == 2
    assert manifest_base[:layout] == :components
    assert manifest_base[:roots] == composition.components
    assert manifest_base[:verify][:component_tests]
    assert manifest_base[:package][:version] == cfg[:version]
    projected_deps = composition.package[:development_dependencies]
    assert manifest_base[:package][:dev_deps] == projected_deps

    assert cfg[:deps] ==
             projected_deps ++
               [{:blitz, "0.5.0", only: [:dev, :test], runtime: false}]

    refute Enum.any?(projected_deps, &(elem(&1, 0) == :blitz))

    assert_raise RuntimeError, ~r/undeclared dependency/, fn ->
      Boundaries.dependencies!(:med_ex, cfg[:deps])
    end

    assert_raise RuntimeError, ~r/development tooling leaked/, fn ->
      Boundaries.dependencies!(
        :med_ex,
        projected_deps ++ [{:blitz, "0.5.0", only: [:dev, :test]}],
        :workspace
      )
    end

    assert manifest_base[:files] == [docs: composition.documents, assets: composition.assets]

    assert Enum.map(manifest_base[:inputs], & &1[:path]) == [
             composition.version_file,
             "mix.exs",
             "build_support/composition.exs",
             composition.package[:docs][:hook_file]
           ]

    assert Enum.all?(manifest_base[:inputs], &(&1[:type] == :file))

    expected_files =
      cfg[:elixirc_paths] ++
        composition.documents ++
        composition.assets ++
        [
          "mix.exs",
          composition.version_file,
          "build_support/composition.exs",
          composition.package[:docs][:hook_file]
        ]

    assert Enum.sort(cfg[:package][:files]) == Enum.sort(expected_files)

    for app <- [:med_ex_opus, :med_ex_rtc] do
      refute Keyword.has_key?(artifacts, app)
      version = File.read!("extensions/#{app}/VERSION") |> String.trim()

      Mix.Project.in_project(app, "extensions/#{app}", [], fn _ ->
        config = Mix.Project.config()
        assert config[:app] == app
        assert config[:version] == version
        refute Enum.any?(config[:deps], &(elem(&1, 0) == :med_ex))

        native = if app == :med_ex_opus, do: ~w(Makefile c_src), else: []

        assert Enum.sort(config[:package][:files]) ==
                 Enum.sort(
                   ~w(.formatter.exs CHANGELOG.md LICENSE README.md VERSION assets lib mix.exs) ++
                     native
                 )

        assert :ok == Boundaries.dependencies!(app, config[:deps])
      end)
    end
  end
end
