ExUnit.start()
Code.require_file("qualification_receipt.exs", __DIR__)
Code.require_file("qualification_sources.exs", __DIR__)

defmodule MedEx.QualificationSourcesTest do
  use ExUnit.Case, async: true
  alias MedEx.Build.{QualificationReceipt, QualificationSources}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "selected-source-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    repo = Path.join(root, "fabric")
    File.mkdir!(repo)
    %{root: root, repo: repo}
  end

  test "external direct source, assets, locks and executable modes invalidate actual receipts", c do
    source = project(c.root, "alternate-sdk")
    select(c.repo, source)
    {receipt, log, input} = passing_receipt(c)
    assert reusable?(receipt, log, input)
    assert QualificationSources.selected(c.repo, %{}) == input

    for relative <- ["lib/source.ex", "priv/asset.bin", "mix.lock"] do
      path = Path.join(source, relative)
      original = File.read!(path)
      File.write!(path, original <> "changed")
      changed = QualificationSources.selected(c.repo, %{})
      refute changed == input
      refute reusable?(receipt, log, changed)
      File.write!(path, original)
      assert QualificationSources.selected(c.repo, %{}) == input
    end

    added = Path.join(source, "lib/added.ex")
    File.write!(added, "defmodule Added, do: def(value, do: :new)\n")
    refute reusable?(receipt, log, QualificationSources.selected(c.repo, %{}))
    File.rm!(added)
    assert QualificationSources.selected(c.repo, %{}) == input

    File.chmod!(Path.join(source, "priv/asset.bin"), 0o700)
    refute reusable?(receipt, log, QualificationSources.selected(c.repo, %{}))
  end

  test "live directory and file symlinks include the bytes actually compiled", c do
    source = project(c.root, "source")
    live = Path.join(c.root, ".weld/v2/live/med_ex")
    File.mkdir_p!(live)
    File.write!(Path.join(live, "mix.exs"), File.read!(Path.join(source, "mix.exs")))
    File.ln_s!(Path.join(source, "lib"), Path.join(live, "lib"))
    File.ln_s!(Path.join(source, "mix.lock"), Path.join(live, "mix.lock"))
    select(c.repo, live)
    {receipt, log, input} = passing_receipt(c)
    live_input = QualificationSources.path(live)

    File.write!(Path.join(source, "lib/source.ex"), "defmodule Source, do: def(value, do: :edited)\n")
    changed = QualificationSources.selected(c.repo, %{})
    refute changed == input
    refute QualificationSources.path(live) == live_input
    refute reusable?(receipt, log, changed)

    {receipt, log, input} = passing_receipt(c)
    File.write!(Path.join(source, "mix.lock"), "%{updated: :lock}\n")
    refute reusable?(receipt, log, QualificationSources.selected(c.repo, %{}))
    refute QualificationSources.selected(c.repo, %{}) == input
  end

  test "new source under an ordinary directory is covered; generated project outputs are not", c do
    source = project(c.root, "source")
    select(c.repo, source)
    input = QualificationSources.selected(c.repo, %{})
    File.mkdir_p!(Path.join(source, "_build/test/lib/source"))
    File.write!(Path.join(source, "_build/test/lib/source/output.beam"), "build product")
    assert QualificationSources.selected(c.repo, %{}) == input

    File.mkdir_p!(Path.join(source, "lib/deps"))
    File.write!(Path.join(source, "lib/deps/source.ex"), "ordinary source directory")
    refute QualificationSources.selected(c.repo, %{}) == input
  end

  test "native override bytes and settings enter the input without modifying environment", c do
    source = project(c.root, "source")
    select(c.repo, source)
    archive = Path.join(c.root, "opus.tar.gz")
    File.write!(archive, "first native archive")
    env = %{"MED_EX_OPUS_TARBALL" => archive, "CFLAGS" => "-O2"}
    {receipt, log, input} = passing_receipt(c, env)

    File.write!(archive, "second native archive")
    refute reusable?(receipt, log, QualificationSources.selected(c.repo, env))
    File.write!(archive, "first native archive")
    assert QualificationSources.selected(c.repo, env) == input

    for {setting, value} <- [
          {"CFLAGS", "-O0"},
          {"AR", "custom-ar"},
          {"RANLIB", "custom-ranlib"},
          {"MED_EX_OPUS_CONFIGURE_FLAGS", "--disable-tests"}
        ] do
      refute reusable?(receipt, log, QualificationSources.selected(c.repo, Map.put(env, setting, value)))
    end

    target = Path.join(c.root, "native-archive")
    File.mkdir!(target)
    File.mkdir!(Path.join(target, "nested"))
    target_archive = Path.join(target, "opus.tar.gz")
    File.write!(target_archive, "traversed native archive")
    File.ln_s!(Path.join(target, "nested"), Path.join(c.root, "bridge"))
    traversed_env = %{env | "MED_EX_OPUS_TARBALL" => c.root <> "/bridge/../opus.tar.gz"}
    {receipt, log, input} = passing_receipt(c, traversed_env)
    assert reusable?(receipt, log, input)
    File.write!(archive, "changed lexical decoy")
    assert QualificationSources.selected(c.repo, traversed_env) == input
    File.write!(target_archive, "changed through intermediate symlink")
    refute reusable?(receipt, log, QualificationSources.selected(c.repo, traversed_env))

    link = Path.join(c.root, "final-symlink.tar.gz")
    File.ln_s!(target_archive, link)

    assert_raise ArgumentError, fn ->
      QualificationSources.selected(c.repo, %{env | "MED_EX_OPUS_TARBALL" => link})
    end
  end

  test "missing sources, cycles and ambiguous selectors cannot reuse evidence", c do
    source = project(c.root, "source")
    select(c.repo, source)
    File.ln_s!(source, Path.join(source, "lib/cycle"))
    assert_raise ArgumentError, fn -> QualificationSources.selected(c.repo, %{}) end
    File.rm!(Path.join(source, "lib/cycle"))

    File.ln_s!(Path.join(c.root, "absent"), Path.join(source, "lib/missing.ex"))
    assert_raise File.Error, fn -> QualificationSources.selected(c.repo, %{}) end
    File.rm!(Path.join(source, "lib/missing.ex"))

    select(c.repo, Path.join(c.root, "missing-project"))
    assert_raise ArgumentError, fn -> QualificationSources.selected(c.repo, %{}) end

    File.write!(Path.join(c.repo, ".mix_sources.json"), ~s({"med_ex":{"path":"one","path":"two"}}))
    assert_raise ArgumentError, fn -> QualificationSources.selected(c.repo, %{}) end
  end

  defp project(root, name) do
    path = Path.join(root, name)
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir!(Path.join(path, "priv"))
    File.write!(Path.join(path, "mix.exs"), "defmodule Source.MixProject, do: def(project, do: [])\n")
    File.write!(Path.join(path, "mix.lock"), "%{}\n")
    File.write!(Path.join(path, "lib/source.ex"), "defmodule Source, do: def(value, do: :original)\n")
    File.write!(Path.join(path, "priv/asset.bin"), <<1, 2, 3>>)
    path
  end

  defp select(repo, source) do
    File.write!(Path.join(repo, ".mix_sources.json"), JSON.encode!(%{"med_ex" => %{"path" => source}}))
  end

  defp passing_receipt(c, env \\ %{}) do
    log = Path.join(c.root, "gate.log")
    receipt = Path.join(c.root, "gate.receipt.json")
    File.write!(log, "fixture gate output\n")
    input = QualificationSources.selected(c.repo, env)
    QualificationReceipt.write!(receipt, input, %{"log" => log}, %{"exit" => 0})
    {receipt, log, input}
  end

  defp reusable?(receipt, log, input),
    do: match?({:ok, _}, QualificationReceipt.read(receipt, input, %{"log" => log}))
end
