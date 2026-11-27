Code.require_file("../../build_support/public_api.exs", __DIR__)

defmodule MedEx.PublicAPITest do
  use ExUnit.Case, async: true
  alias MedEx.Build.PublicAPI
  alias MedEx.Storage.File

  test "designated supported exports have no alternate recording or receipt API" do
    assert :ok = PublicAPI.check!()
    refute function_exported?(MedEx.StreamWriter, :push, 2)
    refute function_exported?(MedEx.StreamWriter, :checkpoint, 1)
    refute function_exported?(MedEx.Serialization, :receipt, 1)
    refute function_exported?(File, :reconcile_index, 2)
  end
end
