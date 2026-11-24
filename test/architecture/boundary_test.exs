Code.require_file("../../build_support/boundary_check.exs", __DIR__)

defmodule MedEx.ArchitectureTest do
  use ExUnit.Case, async: false
  alias MedEx.Build.{Boundaries, Ownership}
  @fixture_path "/fixture/core/med_core/lib/negative.ex"

  test "negative fixtures fail for their own boundary" do
    :persistent_term.put({Boundaries, :core}, MapSet.new([MedEx.StreamSpec]))

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
    lib = Path.join(dir, "core/med_core/lib")
    out = Path.join(dir, "ebin")
    File.mkdir_p!(lib)
    File.mkdir!(out)
    :persistent_term.put({Boundaries, :core}, MapSet.new([MedEx.StreamSpec]))
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

  test "package and canonical source allowlists agree" do
    cfg = Mix.Project.config()
    assert cfg[:app] == :med_ex
    relative = ~w(core/med_core/lib core/med_capture/lib)
    roots = cfg[:elixirc_paths]
    assert length(roots) == 2

    if File.regular?("weld.provenance.json") and
         JSON.decode!(File.read!("weld.provenance.json"))["kind"] == "live" do
      assert Enum.zip(roots, relative)
             |> Enum.all?(fn {path, suffix} ->
               Path.type(path) == :absolute and String.ends_with?(path, "/" <> suffix) and
                 File.dir?(path)
             end)
    else
      assert roots == relative
    end

    assert :ok == Boundaries.dependencies!(:med_ex, cfg[:deps])
    for p <- relative ++ ~w(VERSION priv mix.exs), do: assert(p in cfg[:package][:files])

    assert MapSet.new(File.ls!("priv/static/med_web")) ==
             MapSet.new(~w(session_hook.js pcm_capture.js pcm_worklet.js))
  end
end
