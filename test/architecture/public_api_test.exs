Code.require_file("../../build_support/public_api.exs", __DIR__)

defmodule MedEx.PublicAPITest do
  use ExUnit.Case, async: true

  test "designated supported exports have no alternate recording or receipt API" do
    assert :ok = MedEx.Build.PublicAPI.check!()
    refute function_exported?(MedEx.StreamWriter, :push, 2)
    refute function_exported?(MedEx.StreamWriter, :checkpoint, 1)
    refute function_exported?(MedEx.Serialization, :receipt, 1)
    refute function_exported?(MedEx.Storage.File, :reconcile_index, 2)
  end
end
