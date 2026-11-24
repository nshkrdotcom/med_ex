defmodule MedEx.ControlWireTest do
  use ExUnit.Case, async: true
  alias MedEx.Wire.Control

  test "rejects nested duplicate keys and invalid schema, retains namespaced values" do
    assert {:error, :duplicate_key} =
             Control.decode(~s({"schema":"medex.device.v1","type":"status","v":{"x":1,"x":2}}), [
               "status"
             ])

    {:ok, bytes} = Control.encode("status", %{"vendor:status" => "pending"})
    assert {:ok, %{"vendor:status" => "pending"}} = Control.decode(bytes, ["status"])
    assert {:error, :unsupported_message} = Control.decode(bytes, ["finish"])
    assert {:error, :message_limit} = Control.decode(:binary.copy(<<32>>, 16_385), [])
    assert {:ok, 9_007_199_254_740_993} = Control.uint64("9007199254740993")

    for bad <- ["001", "-1", "18446744073709551616", 7],
        do: assert({:error, _} = Control.uint64(bad))
  end
end
