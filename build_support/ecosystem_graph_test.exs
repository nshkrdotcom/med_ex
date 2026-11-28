ExUnit.start()
Code.require_file("ecosystem_graph.exs", __DIR__)
Code.require_file("qualification_receipt.exs", __DIR__)

defmodule MedEx.EcosystemGraphTest do
  use ExUnit.Case, async: true
  alias MedEx.Build.{EcosystemGraph, QualificationReceipt}

  @nodes [
    {"weld-ci", "weld", [], []},
    {"medex-core", "med_ex", [], []},
    {"medex-prepare", "med_ex", ["medex-core"], []},
    {"medex-remote", "med_ex", ["medex-prepare"], []},
    {"fabric-projects", "med_fabric", [], []},
    {"fabric-sources", "med_fabric", ["medex-prepare", "fabric-projects"], []},
    {"fabric-remote", "med_fabric", ["medex-remote", "fabric-projects"], []}
  ]

  test "consumer scope requires neither Weld CI nor a published remote commit" do
    ids = @nodes |> EcosystemGraph.select(nil) |> Enum.map(&elem(&1, 0))
    assert ids == ~w(medex-core medex-prepare fabric-projects fabric-sources)
    assert Enum.all?(EcosystemGraph.select(@nodes, nil), &(elem(&1, 1) != "weld"))

    assert @nodes |> EcosystemGraph.select("fabric-remote") |> Enum.map(&elem(&1, 0)) ==
             ~w(medex-core medex-prepare medex-remote fabric-projects fabric-remote)

    assert_raise KeyError, fn -> EcosystemGraph.select(@nodes, "unknown") end
  end

  test "a real command failure blocks descendants but independent work completes" do
    parent = self()

    results =
      @nodes
      |> EcosystemGraph.select(nil)
      |> EcosystemGraph.run(fn {id, _, _, _}, dependencies ->
        send(parent, {:ran, id, dependencies})

        {_, status} =
          System.cmd("sh", ["-c", if(id == "medex-core", do: "exit 7", else: "exit 0")])

        if status != 0, do: raise("command exited #{status}")
        "receipt-#{id}"
      end)

    assert results["medex-core"] == {:failed, "command exited 7"}
    assert results["medex-prepare"] == {:blocked, ["medex-core"]}
    assert results["fabric-projects"] == {:ok, "receipt-fabric-projects"}
    assert results["fabric-sources"] == {:blocked, ["medex-prepare"]}
    refute EcosystemGraph.successful?(results)
    assert_received {:ran, "medex-core", %{}}
    assert_received {:ran, "fabric-projects", %{}}
    refute_received {:ran, "medex-prepare", _}
  end

  test "only exact unchanged input and output reuse a passing receipt" do
    root = Path.join(System.tmp_dir!(), "ecosystem-receipt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    log = Path.join(root, "pass.log")
    receipt = Path.join(root, "pass.receipt.json")
    File.write!(log, "real gate output\n")
    input = QualificationReceipt.fingerprint({2, "source", "lock", "tool", "fixture"})
    QualificationReceipt.write!(receipt, input, %{"log" => log}, %{"exit" => 0})
    assert {:ok, _} = QualificationReceipt.read(receipt, input, %{"log" => log})

    for changed <- ["source", "lock", "tool", "fixture"] do
      refute match?(
               {:ok, _},
               QualificationReceipt.read(
                 receipt,
                 QualificationReceipt.fingerprint({input, changed}),
                 %{"log" => log}
               )
             )
    end

    File.write!(log, "changed output\n")
    assert :miss = QualificationReceipt.read(receipt, input, %{"log" => log})
  end

  test "development runs only ordinary source tests, never release prerequisites" do
    assert EcosystemGraph.fast() == [
             {"medex-tests", "med_ex", [], ["mix", "test"]},
             {"fabric-tests", "med_fabric", [], ["mix", "test"]}
           ]

    release_ids = MapSet.new(@nodes, &elem(&1, 0))
    assert Enum.all?(EcosystemGraph.fast(), &(not MapSet.member?(release_ids, elem(&1, 0))))
  end

  @tag :tmp_dir
  test "native receipts bind required reports and locks, not the installed build tree", %{
    tmp_dir: root
  } do
    files = QualificationReceipt.native_outputs(root, "fabric-native")
    outputs = Map.new(files, &{&1, &1})
    receipt = Path.join(root, "gate.receipt.json")
    input = QualificationReceipt.fingerprint(:native)

    for path <- files do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "proof")
    end

    # Generated JSON symlinks must not make a successful native gate unrecordable.
    build = Path.join(root, "consumers/exam/_build/generated.json")
    File.mkdir_p!(Path.dirname(build))
    File.ln_s!("missing-target", build)

    assert Path.join(root, "native.json") in files
    assert Path.join(root, "detached.json") in files
    assert Path.join(root, "installed/exam-mix.lock") in files
    assert Path.join(root, "detached.json.inputs/combined-mix.lock") in files
    refute build in files
    assert :ok = QualificationReceipt.write!(receipt, input, outputs, %{})
    assert {:ok, %{}} = QualificationReceipt.read(receipt, input, outputs)

    lock = Path.join(root, "installed/exam-mix.lock")
    File.write!(lock, "changed lock")
    assert :miss = QualificationReceipt.read(receipt, input, outputs)
    File.write!(lock, "proof")
    assert {:ok, %{}} = QualificationReceipt.read(receipt, input, outputs)

    required = Path.join(root, "detached.json")
    File.rm!(required)
    assert :miss = QualificationReceipt.read(receipt, input, outputs)

    assert_raise RuntimeError,
                 ~r/Cannot record qualification output .*detached.json: :enoent/,
                 fn ->
                   QualificationReceipt.write!(receipt, input, outputs, %{})
                 end

    File.ln_s!(Path.join(root, "native.json"), required)

    assert_raise RuntimeError,
                 ~r/Cannot record qualification output .*detached.json:.*not_regular/,
                 fn ->
                   QualificationReceipt.write!(receipt, input, outputs, %{})
                 end
  end

  test "both soak receipts require filesystem, reports and role locks, not detached release proof" do
    for gate <- ~w(fabric-soak-off fabric-soak-isolated) do
      files = QualificationReceipt.native_outputs("/evidence", gate)
      assert "/evidence/native.json" in files
      assert "/evidence/exit-status" in files
      assert "/evidence/filesystem.txt" in files
      assert "/evidence/installed/preview-mix.lock" in files
      refute "/evidence/detached.json" in files
    end
  end
end
