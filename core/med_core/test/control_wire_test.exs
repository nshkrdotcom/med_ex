defmodule MedEx.ControlWireTest do
  use ExUnit.Case, async: true
  alias MedEx.Wire.Control

  defp binding,
    do: %{
      "acquisition" => "a",
      "profile" => "paired_exam",
      "generation" => "1",
      "connection" => "c"
    }

  test "one strict v2 codec rejects nested duplicates, unsupported fields and incorrect counters" do
    duplicate = ~s({"schema":"medex.acquisition.v2","type":"heartbeat","binding":{"x":1,"x":2}})
    assert {:error, :duplicate_key} = Control.decode(duplicate, ["heartbeat"])
    fields = %{"binding" => binding(), "operation_id" => "o", "nonce" => "n"}
    assert {:ok, bytes} = Control.encode("heartbeat", fields)
    assert {:ok, message} = Control.decode(bytes, ["heartbeat"])
    assert message["schema"] == "medex.acquisition.v2"
    assert {:error, :unsupported_message} = Control.decode(bytes, ["finish"])

    assert {:error, :invalid_message} =
             Control.encode("heartbeat", Map.put(fields, "extra", true))

    assert {:error, :invalid_message} =
             Control.encode("heartbeat", put_in(fields, ["binding", "generation"], 1))

    assert {:error, :message_limit} = Control.decode(:binary.copy(<<32>>, 16_385), [])
    assert {:ok, 9_007_199_254_740_993} = Control.uint64("9007199254740993")

    for bad <- ["001", "-1", "18446744073709551616", 7, nil, [], %{}],
        do: assert({:error, _} = Control.uint64(bad))
  end

  test "revision mismatch and missing authenticated binding cannot be encoded" do
    fields = %{
      "operation_id" => "hello",
      "api_revision" => 1,
      "acquisition" => "a",
      "encounter" => "e",
      "profile" => "plx_spot_check",
      "boot" => "b",
      "descriptors" => %{}
    }

    assert {:error, :invalid_message} = Control.encode("hello", fields)
    assert {:ok, _} = Control.encode("hello", %{fields | "api_revision" => 2})
    assert {:error, :invalid_message} = Control.encode("checkpoint", %{"operation_id" => "o"})
  end
end
