defmodule MedEx.ControlWireTest do
  use ExUnit.Case, async: true
  alias MedEx.{Receipt, Serialization}
  alias MedEx.Wire.{Control, Credit}

  defp test_binding,
    do: %{
      "acquisition" => "a",
      "profile" => "paired_exam",
      "generation" => "1",
      "connection" => "c"
    }

  test "one strict v2 codec rejects nested duplicates, unsupported fields and incorrect counters" do
    duplicate = ~s({"schema":"medex.acquisition.v2","type":"heartbeat","binding":{"x":1,"x":2}})
    assert {:error, :duplicate_key} = Control.decode(duplicate, ["heartbeat"])
    fields = %{"binding" => test_binding(), "operation_id" => "o", "nonce" => "n"}
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

  test "gap IDs reserve four bytes for their canonical credit operation prefix" do
    for size <- [1, 92] do
      id = String.duplicate("a", size)
      fields = gap(id)
      assert_valid("gap", fields)
      assert {:ok, bytes} = Control.encode("gap", fields)
      assert {:ok, ledger} = Credit.new(test_binding())

      assert {:ok, _, :new} =
               Credit.reserve(ledger, test_binding(), %{
                 id: "gap-" <> id,
                 fingerprint: String.duplicate("a", 64),
                 sequence: 1,
                 sample: 960,
                 bytes: byte_size(bytes)
               })
    end

    for size <- [0, 93, 94, 95, 96], do: assert_invalid("gap", gap(String.duplicate("a", size)))

    # Identifiers are ASCII: byte-sized UTF-8 strings are not legal identifiers.
    for id <- [String.duplicate("é", 46), String.duplicate("é", 47)],
        do: assert_invalid("gap", gap(id))

    assert_valid("heartbeat", %{
      "binding" => test_binding(),
      "operation_id" => String.duplicate("a", 96),
      "nonce" => String.duplicate("b", 96)
    })
  end

  test "durable waveform and event replies are disjoint on key presence" do
    receipt = receipt()
    common = %{"binding" => test_binding(), "operation_id" => "op"}
    waveform = Map.put(common, "receipt", receipt)
    event = Map.merge(common, %{"event_id" => "event", "fingerprint" => String.duplicate("b", 64)})
    assert_valid("durable", waveform)
    assert_valid("durable", event)

    assert_valid("durable", Map.merge(waveform, %{
      "handoff" => %{
        "asserted_by" => "authenticated_host",
        "previous" => receipt,
        "successor" => receipt,
        "imported" => receipt
      },
      "credit_frames" => 15,
      "credit_bytes" => 262_144
    }))

    for fields <- [
          common,
          Map.put(common, "event_id", "event"),
          Map.put(common, "fingerprint", String.duplicate("b", 64)),
          Map.put(waveform, "event_id", "event"),
          Map.put(waveform, "fingerprint", String.duplicate("b", 64)),
          Map.merge(waveform, Map.take(event, ["event_id", "fingerprint"])),
          Map.put(waveform, "event_id", nil),
          Map.put(waveform, "fingerprint", nil),
          Map.put(event, "receipt", nil),
          Map.put(event, "fingerprint", "invalid"),
          Map.put(waveform, "receipt", %{}),
          put_in(waveform, ["receipt", "accepted_sample"], "1"),
          Map.put(waveform, "unknown", true)
        ] do
      assert_invalid("durable", fields)
    end

    assert {:ok, bytes} = Control.encode("durable", waveform)
    duplicate = String.replace_prefix(bytes, "{", ~s({"receipt":null,))
    assert {:error, :duplicate_key} = Control.decode(duplicate, ["durable"])
  end

  defp gap(id),
    do: %{
      "binding" => test_binding(),
      "operation_id" => "gap-request",
      "id" => id,
      "first" => "0",
      "end" => "960",
      "first_sequence" => "0",
      "next_sequence" => "1",
      "irreversible" => true,
      "cause" => "source_gap"
    }

  defp receipt do
    Serialization.to_map(%Receipt{
      stream_id: "audio",
      source_epoch: 0,
      descriptor_ref: String.duplicate("a", 64),
      fence: "fence",
      journal_id: "journal",
      journal_generation: 1,
      journal_digest: String.duplicate("b", 64),
      accepted_sequence: 0,
      accepted_sample: 0,
      durable_sequence: 0,
      durable_sample: 0
    })
  end

  defp assert_valid(type, fields) do
    assert {:ok, bytes} = Control.encode(type, fields)
    assert {:ok, decoded} = Control.decode(bytes, [type])
    assert Map.drop(decoded, ["schema", "type"]) == fields
  end

  defp assert_invalid(type, fields) do
    assert {:error, :invalid_message} = Control.encode(type, fields)
    bytes = JSON.encode!(Map.merge(fields, %{"schema" => Control.schema(), "type" => type}))
    assert {:error, :invalid_message} = Control.decode(bytes, [type])
  end
end
