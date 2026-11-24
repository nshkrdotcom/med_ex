defmodule MedExRTC.SourceSelectionTest do
  use ExUnit.Case, async: false
  alias MedExRTC.BuildSources, as: Sources

  setup do
    root = Path.join(System.tmp_dir!(), "medex-source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "apps/exam"))
    File.mkdir_p!(Path.join(root, "sdk"))
    File.write!(Path.join(root, "sdk/mix.exs"), "[app: :med_ex]\n")
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      project: Path.join(root, "apps/exam"),
      defaults: [{:med_ex, "~> 0.2.0", github: "owner/sdk", ref: "old", runtime: true}]
    }
  end

  test "default unchanged; selected path replaces SCM and isolates all mutable state", c do
    assert {c.defaults, []} == Sources.resolve(c.defaults, c.project, c.root)
    File.write!(Path.join(c.root, ".mix_sources.json"), ~s({"med_ex":{"path":"sdk"}}))
    assert {[{:med_ex, "~> 0.2.0", opts}], paths} = Sources.resolve(c.defaults, c.project, c.root)
    assert opts[:path] == Path.join(c.root, "sdk")
    assert opts[:runtime] == true
    refute Keyword.has_key?(opts, :github)
    refute Keyword.has_key?(opts, :ref)
    assert Enum.all?([:lockfile, :deps_path, :build_path], &is_binary(paths[&1]))

    File.write!(
      Path.join(c.root, ".mix_sources.json"),
      ~s({"med_ex":{"github":"owner/sdk","ref":"new"}})
    )

    {_deps, alternate} = Sources.resolve(c.defaults, c.project, c.root)
    assert alternate[:lockfile] != paths[:lockfile]
    assert alternate[:build_path] != paths[:build_path]
    assert alternate[:deps_path] != paths[:deps_path]
  end

  test "shared provider selections do not pull media into a headless project", c do
    File.write!(
      Path.join(c.root, ".mix_sources.json"),
      ~s({"med_ex":{"path":"sdk"},"med_ex_rtc":{"path":"not-installed"},"med_ex_opus":{"path":"not-installed"}})
    )

    {deps, _paths} = Sources.resolve(c.defaults, c.project, c.root)
    assert Enum.map(deps, &elem(&1, 0)) == [:med_ex]
  end

  test "runner lock environment cannot override an alternate dependency context", c do
    file = Path.join(c.root, ".mix_sources.json")
    File.write!(file, ~s({"med_ex":{"path":"sdk"}}))
    original = System.get_env("MIX_LOCKFILE")

    try do
      System.put_env("MIX_LOCKFILE", "stale.lock")

      assert_raise Mix.Error, ~r/MIX_LOCKFILE/, fn ->
        Sources.resolve(c.defaults, c.project, c.root)
      end
    after
      if original,
        do: System.put_env("MIX_LOCKFILE", original),
        else: System.delete_env("MIX_LOCKFILE")
    end
  end

  test "wrong path identity fails without executing the selected Mix file", c do
    File.write!(Path.join(c.root, "sdk/mix.exs"), "[app: :wrong_app]")
    File.write!(Path.join(c.root, ".mix_sources.json"), ~s({"med_ex":{"path":"sdk"}}))

    assert_raise Mix.Error, ~r/Wrong application/, fn ->
      Sources.resolve(c.defaults, c.project, c.root)
    end
  end

  test "rejects duplicate keys and conflicting source choices", c do
    file = Path.join(c.root, ".mix_sources.json")
    File.write!(file, ~s({"med_ex":{"path":"sdk"},"med_ex":{"path":"elsewhere"}}))
    assert_raise Mix.Error, fn -> Sources.resolve(c.defaults, c.project, c.root) end
    File.write!(file, ~s({"med_ex":{"path":"sdk","github":"owner/sdk","ref":"x"}}))
    assert_raise Mix.Error, fn -> Sources.resolve(c.defaults, c.project, c.root) end
  end
end
