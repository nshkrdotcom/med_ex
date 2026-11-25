Code.require_file("../../build_support/qualification_receipt.exs", __DIR__)

defmodule MedEx.QualificationReceiptTest do
  use ExUnit.Case, async: true

  alias MedEx.Build.QualificationReceipt, as: Receipt

  @tag :tmp_dir
  test "requires matching inputs and current outputs to reuse a successful gate", %{tmp_dir: dir} do
    receipt = Path.join(dir, "receipt.json")
    log = Path.join(dir, "test.log")
    File.write!(log, "actual gate output")
    key = Receipt.fingerprint({:profile, "first"})
    paths = %{"log" => log}
    assert :ok = Receipt.write!(receipt, key, paths, %{"tests" => 2})
    assert {:ok, %{"tests" => 2}} = Receipt.read(receipt, key, paths)
    assert :miss = Receipt.read(receipt, Receipt.fingerprint({:profile, "second"}), paths)
    assert :miss = Receipt.read(receipt, key, %{})
    File.write!(log, "other gate output")
    assert :miss = Receipt.read(receipt, key, paths)
    File.write!(receipt, "{incomplete")
    assert :miss = Receipt.read(receipt, key, paths)
  end
end
