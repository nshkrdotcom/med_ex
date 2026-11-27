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
end
