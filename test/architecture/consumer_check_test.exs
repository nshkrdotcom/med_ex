Code.require_file("../../build_support/check_consumers.exs", __DIR__)

defmodule MedEx.ConsumerCheckTest do
  use ExUnit.Case, async: true

  test "registry package selection accepts one source and requires a registry command" do
    for selection <- [[], [projected_packages: true], [prepared_packages: true]] do
      assert :ok =
               MedEx.ConsumerCheck.validate_options!([registry: true] ++ selection, ["true"])
    end

    invoker = Path.expand("../..", __DIR__)

    assert :ok =
             MedEx.ConsumerCheck.validate_options!(
               [registry: true, projected_packages: true, weld_invoker: invoker],
               ["true"]
             )

    for {options, command} <- [
          {[projected_packages: true], []},
          {[projected_packages: true], ["true"]},
          {[registry: true, projected_packages: true], []},
          {[registry: true, projected_packages: true, prepared_packages: true], ["true"]},
          {[registry: true, weld_invoker: invoker], ["true"]},
          {[registry: true, projected_packages: true, weld_invoker: "relative"], ["true"]},
          {[registry: true, projected_packages: true, weld_invoker: __DIR__], ["true"]}
        ] do
      assert_raise ArgumentError, fn ->
        MedEx.ConsumerCheck.validate_options!(options, command)
      end
    end
  end

  @tag :tmp_dir
  test "projected registry input must match its reported source revision and portable bytes", %{
    tmp_dir: root
  } do
    on_exit(fn -> File.rm_rf!(root) end)
    revision = String.duplicate("a", 40)
    File.write!(Path.join(root, "mix.exs"), "project\n")
    File.chmod!(Path.join(root, "mix.exs"), 0o644)
    identity = digest(:erlang.term_to_binary({"mix.exs", 0, digest("project\n")}))

    File.write!(
      Path.join(root, "weld.provenance.json"),
      JSON.encode!(%{
        schema: "weld.projection/v1",
        artifact: "med_ex",
        kind: "full",
        artifact_id: identity
      })
    )

    File.write!(
      Path.join(root, "projection.lock.json"),
      JSON.encode!(%{artifact: %{id: "med_ex"}, projection: %{git_revision: revision}})
    )

    assert :ok = MedEx.ConsumerCheck.verify_full_projection!(root, :med_ex, revision)

    assert_raise RuntimeError, ~r/source revision/, fn ->
      MedEx.ConsumerCheck.verify_full_projection!(root, :med_ex, String.duplicate("b", 40))
    end

    assert_raise RuntimeError, ~r/provenance/, fn ->
      MedEx.ConsumerCheck.verify_full_projection!(root, :med_ex_opus, revision)
    end

    File.chmod!(Path.join(root, "mix.exs"), 0o744)

    assert_raise RuntimeError, ~r/portable content/, fn ->
      MedEx.ConsumerCheck.verify_full_projection!(root, :med_ex, revision)
    end

    File.chmod!(Path.join(root, "mix.exs"), 0o644)
    File.write!(Path.join(root, "mix.exs"), "changed project\n")

    assert_raise RuntimeError, ~r/portable content/, fn ->
      MedEx.ConsumerCheck.verify_full_projection!(root, :med_ex, revision)
    end
  end

  test "normalizes Hex requirements without losing identity or constraints" do
    properties = [
      {"app", "med_ex"},
      {"name", "med_ex"},
      {"optional", false},
      {"repository", "hexpm"},
      {"requirement", "~> 0.4.0"}
    ]

    expected = %{"med_ex" => Map.new(properties)}

    assert %{} == MedEx.ConsumerCheck.normalize_requirements!([])

    assert expected ==
             MedEx.ConsumerCheck.normalize_requirements!([properties])

    assert expected ==
             MedEx.ConsumerCheck.normalize_requirements!([{"med_ex", properties}])

    assert_raise RuntimeError, ~r/Duplicate Hex requirement/, fn ->
      MedEx.ConsumerCheck.normalize_requirements!([properties, properties])
    end

    assert_raise RuntimeError, ~r/Hex requirement name mismatch/, fn ->
      MedEx.ConsumerCheck.normalize_requirements!([{"wrong", properties}])
    end
  end

  test "Opus packages must contain every input needed for the native build" do
    required = ~w(mix.exs lib/med_ex/opus/provider.ex Makefile
                  c_src/opus_encoder.c c_src/build_native.sh c_src/vendor/SHA256SUMS)
    files = Enum.map(required, &{&1, "fixture bytes"})
    assert :ok = MedEx.ConsumerCheck.verify_package_files!(:med_ex_opus, files)

    for missing <- required -- ["mix.exs"] do
      assert_raise RuntimeError, ~r/Opus build input missing/, fn ->
        MedEx.ConsumerCheck.verify_package_files!(
          :med_ex_opus,
          List.keydelete(files, missing, 0)
        )
      end
    end
  end

  @tag :tmp_dir
  test "native source and build recipe changes invalidate path qualification", %{tmp_dir: root} do
    on_exit(fn -> File.rm_rf!(root) end)
    files = ~w(Makefile c_src/opus_encoder.c c_src/build_native.sh c_src/vendor/SHA256SUMS)

    for relative <- files do
      file = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "original")
    end

    original = MedEx.ConsumerCheck.path_fingerprint(root)

    for relative <- files do
      file = Path.join(root, relative)
      File.write!(file, "changed")
      refute MedEx.ConsumerCheck.path_fingerprint(root) == original
      File.write!(file, "original")
    end
  end

  @tag :tmp_dir
  test "prepared verification checks the report, source bytes and executable bits", %{
    tmp_dir: root
  } do
    files = [
      {"mix.exs", "project\n", 0},
      {"projection.lock.json", "{}\n", 0},
      {"script", "#!/bin/sh\n", 0o100},
      {"weld.provenance.json", "{}\n", 0}
    ]

    for {path, bytes, executable} <- files do
      File.write!(Path.join(root, path), bytes)
      File.chmod!(Path.join(root, path), 0o644 + executable)
    end

    entries =
      Enum.map(files, fn {path, bytes, executable} -> {path, executable, digest(bytes)} end)

    tree = Enum.map_join(entries, "\n", fn {path, _, hash} -> path <> ":" <> hash end)

    expected = %{
      "project_sha256" => digest(tree),
      "project_identity" => digest(Enum.map(entries, &:erlang.term_to_binary/1))
    }

    assert :ok = MedEx.ConsumerCheck.verify_prepared_tree!(root, expected)
    File.chmod!(Path.join(root, "script"), 0o644)

    assert_raise RuntimeError, ~r/prepared project integrity/, fn ->
      MedEx.ConsumerCheck.verify_prepared_tree!(root, expected)
    end

    File.chmod!(Path.join(root, "script"), 0o744)
    File.write!(Path.join(root, "projection.lock.json"), "{\"changed\":true}\n")

    assert_raise RuntimeError, ~r/prepared project integrity/, fn ->
      MedEx.ConsumerCheck.verify_prepared_tree!(root, expected)
    end
  end

  @tag :tmp_dir
  test "tracked verification uses exact tree paths, blobs and Git executable modes", %{
    tmp_dir: root
  } do
    checkout = Path.join(root, "checkout")
    prepared = Path.join(root, "prepared")
    File.mkdir!(checkout)
    File.mkdir!(prepared)
    git!(checkout, ["init", "-q"])
    git!(checkout, ["config", "core.fileMode", "true"])
    git!(checkout, ["config", "core.autocrlf", "false"])

    for directory <- [checkout, prepared] do
      File.write!(Path.join(directory, ".formatter.exs"), "[]\n")
      File.write!(Path.join(directory, "projection.lock.json"), "{}\n")
      File.mkdir!(Path.join(directory, "test"))
      script = Path.join(directory, "test/probe\t.sh")
      File.write!(script, "#!/bin/sh\n")
      File.chmod!(script, 0o744)
    end

    git!(checkout, ["add", "-f", "."])
    commit!(checkout, "Original tracking message")
    tracked = tree(checkout, "HEAD")
    commit!(checkout, "Different commit with the same tree")

    assert tree(checkout, "HEAD") == tracked
    assert :ok = MedEx.ConsumerCheck.verify_tracked_tree!(prepared, tracked)

    script = Path.join(prepared, "test/probe\t.sh")
    File.chmod!(script, 0o644)

    assert_raise RuntimeError, ~r/Tracked projection tree/, fn ->
      MedEx.ConsumerCheck.verify_tracked_tree!(prepared, tracked)
    end

    File.chmod!(script, 0o744)
    File.write!(Path.join(prepared, "projection.lock.json"), "{\"changed\":true}\n")

    assert_raise RuntimeError, ~r/Tracked projection tree/, fn ->
      MedEx.ConsumerCheck.verify_tracked_tree!(prepared, tracked)
    end

    File.write!(Path.join(prepared, "projection.lock.json"), "{}\n")
    File.write!(Path.join(prepared, "extra"), "extra\n")

    assert_raise RuntimeError, ~r/Tracked projection tree/, fn ->
      MedEx.ConsumerCheck.verify_tracked_tree!(prepared, tracked)
    end
  end

  defp tree(checkout, revision),
    do: git!(checkout, ["ls-tree", "-r", "-z", "--full-tree", revision])

  defp commit!(checkout, message) do
    git!(checkout, [
      "-c",
      "user.name=MedEx Test",
      "-c",
      "user.email=test@example.test",
      "commit",
      "-q",
      "--no-gpg-sign",
      "--allow-empty",
      "-m",
      message
    ])
  end

  defp git!(checkout, args) do
    {output, status} = System.cmd("git", args, cd: checkout, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
