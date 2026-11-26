defmodule MedEx.CorePropertiesTest do
  use ExUnit.Case, async: true

  alias MedEx.CanonicalJSON
  alias MedEx.Wire.FrameV1

  test "Wire.FrameV1 round-trips arbitrary payloads and coordinates" do
    :rand.seed(:exsss, {101, 202, 303})

    for i <- 1..50 do
      len = :rand.uniform(256)
      payload = :crypto.strong_rand_bytes(len)

      frame = %FrameV1{
        stream_number: i,
        source_epoch: rem(i, 5),
        config_epoch: 1,
        sequence: i * 10,
        first_sample: i * 100,
        sample_count: len,
        payload: payload
      }

      assert {:ok, bin} = FrameV1.encode(frame)
      assert {:ok, decoded} = FrameV1.decode(bin)
      assert decoded == frame
    end
  end

  test "CanonicalJSON encodes MEJ1 maps deterministically regardless of key insertion order" do
    a = %{"z" => "1", "a" => [true, false, nil, "hi"], "m" => %{"b" => "2", "a" => "1"}}
    b = %{"m" => %{"a" => "1", "b" => "2"}, "a" => [true, false, nil, "hi"], "z" => "1"}
    assert CanonicalJSON.encode(a) == CanonicalJSON.encode(b)
    assert_raise ArgumentError, fn -> CanonicalJSON.encode(%{"n" => 1}) end
  end
end
