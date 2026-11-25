defmodule MedEx.CanonicalJSONTest do
  use ExUnit.Case, async: true
  alias MedEx.CanonicalJSON

  test "stable bytes retain Unicode and integers beyond JavaScript precision" do
    metadata = %{"z" => nil, "sample" => "9007199254740993", "label" => "ECG µV\n"}
    expected = "{\"label\":\"ECG µV\\n\",\"sample\":\"9007199254740993\",\"z\":null}"
    assert CanonicalJSON.encode(metadata) == expected
    assert JSON.decode!(expected) == metadata
  end

  test "rejects ambiguous numeric serialization and invalid keys" do
    assert_raise ArgumentError, fn -> CanonicalJSON.encode(%{"value" => 0.1}) end
    assert_raise ArgumentError, fn -> CanonicalJSON.encode(%{"value" => 1}) end
    assert_raise ArgumentError, fn -> CanonicalJSON.encode(%{"μ" => "1"}) end

    assert CanonicalJSON.encode(%{"x" => <<0, 8, 34, 92>>}) ==
             "{\"x\":\"\\u0000\\b\\\"\\\\\"}"
  end
end
