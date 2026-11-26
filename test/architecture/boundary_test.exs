Code.require_file("../../build_support/boundary_check.exs", __DIR__)

defmodule MedEx.ArchitectureTest do
  use ExUnit.Case, async: false

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    on_exit(&MedEx.Build.Boundaries.clear/0)
    :ok
  end

  alias MedEx.Build.{Boundaries, Ownership}
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
            {"def bad(pid), do: MedEx.StreamWriter.receipt(pid)", "reverse dependency"},
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
    assert :ok == Boundaries.dependencies!(:med_ex, cfg[:deps])

    manifest_base = artifacts[:med_ex]
    assert manifest_base[:mode] == :package_projection
    assert manifest_base[:roots] == composition.components
    assert manifest_base[:verify][:component_tests]
    assert manifest_base[:package][:version] == cfg[:version]

    expected_files =
      cfg[:elixirc_paths] ++
        composition.documents ++
        composition.assets ++
        ["mix.exs", composition.version_file, "build_support/composition.exs"]

    assert Enum.sort(cfg[:package][:files]) == Enum.sort(expected_files)

    for app <- [:med_ex_opus, :med_ex_rtc] do
      extension = artifacts[app]
      assert extension[:roots] == ["extensions/#{app}"]
      assert extension[:mode] == :source_project
      assert extension[:external_projects] == ["."]
      version = File.read!("extensions/#{app}/VERSION") |> String.trim()
      assert extension[:package][:version] == version

      Mix.Project.in_project(app, "extensions/#{app}", [], fn _ ->
        config = Mix.Project.config()
        assert config[:app] == app
        assert config[:version] == version
        assert {:med_ex, "~> 0.2.0"} in config[:deps]

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
