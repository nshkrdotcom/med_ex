defmodule MedEx.SemanticVectorsTest do
  use ExUnit.Case, async: true
  alias MedEx.{CanonicalJSON, FrameFingerprint, SampleFrame, Serialization}
  alias MedEx.Wire.FrameV1
  @dir Path.join(__DIR__, "fixtures/wire")
  test "uses independent Python-produced binary, metadata and fingerprint vectors" do
    v = File.read!(Path.join(@dir, "reference_vectors.json")) |> JSON.decode!()
    bytes = File.read!(Path.join(@dir, v["mex1"]["file"]))
    assert Serialization.sha256(bytes) == v["mex1"]["sha256"]
    assert {:ok, f} = FrameV1.decode(bytes)
    assert f.first_sample == 9_007_199_254_740_993
    assert {:ok, ^bytes} = FrameV1.encode(f)

    attrs =
      f
      |> Map.from_struct()
      |> Map.drop([:stream_number])
      |> Map.merge(%{stream_id: "ecg", descriptor_ref: String.duplicate("a", 64)})

    assert FrameFingerprint.of(struct!(SampleFrame, attrs)) == v["semantic_fingerprint"]["sha256"]
    metadata = File.read!(Path.join(@dir, v["mej1"]["file"]))
    assert CanonicalJSON.encode(v["mej1"]["input"]) == metadata
    assert CanonicalJSON.decode(metadata) == {:ok, v["mej1"]["input"]}

    for bad <- [~s({"a":"1","a":"1"}), ~s({"a":1}), ~s({ "a":"1"}), ~s({"a":"\\u0061"})] do
      assert {:error, :invalid_mej1} = CanonicalJSON.decode(bad)
    end
  end

  test "generic metadata never loses extra provenance through fact serialization" do
    metadata = %{name: "filter", origin: :claimed, value: true, source_record: "record-7"}

    assert Serialization.to_map(metadata) == %{
             "name" => "filter",
             "origin" => "claimed",
             "value" => true,
             "source_record" => "record-7"
           }

    assert Serialization.to_map(%{name: "rate", origin: :observed, value: 7}) == %{
             "name" => "rate",
             "origin" => "observed",
             "value" => %{"integer" => "7"}
           }
  end

  test "technical receipt decoding refuses undeclared wrapper or authority fields" do
    receipt = %MedEx.Receipt{
      stream_id: "ecg",
      source_epoch: 0,
      descriptor_ref: String.duplicate("a", 64),
      fence: "attempt-1",
      journal_id: "journal-1",
      journal_generation: 1,
      journal_digest: String.duplicate("b", 64),
      accepted_sequence: 1,
      accepted_sample: 2,
      durable_sequence: 1,
      durable_sample: 2
    }

    wire = Serialization.to_map(receipt)
    assert {:ok, ^receipt} = MedEx.Receipt.parse(wire)

    for extra <- [%{"type" => "durable"}, %{"replacement_fence" => "attempt-2"}] do
      assert {:error, :invalid_receipt} = MedEx.Receipt.parse(Map.merge(wire, extra))
    end
  end
end
