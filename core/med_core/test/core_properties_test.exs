defmodule MedEx.CorePropertiesTest do
  use ExUnit.Case, async: true

  alias MedEx.CanonicalJSON
  alias MedEx.Wire.FrameV1

  test "Wire.FrameV1 round-trips arbitrary payloads and coordinates" do
    :rand.seed(:exsss, {101, 202, 303})

    for i <- 1..50 do
      len = :rand.uniform(256)
      payload = for _ <- 1..len, into: <<>>, do: <<:rand.uniform(256) - 1>>

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

  test "CanonicalJSON emits sorted keys at every nesting level" do
    a = %{"z" => "1", "a" => [true, false, nil, "hi"], "m" => %{"b" => "2", "a" => "1"}}

    assert CanonicalJSON.encode(a) ==
             ~s({"a":[true,false,null,"hi"],"m":{"a":"1","b":"2"},"z":"1"})

    assert_raise ArgumentError, fn -> CanonicalJSON.encode(%{"n" => 1}) end
  end
end
