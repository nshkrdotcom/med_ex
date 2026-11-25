defmodule MedEx.Wire.FrameV1Test do
  use ExUnit.Case, async: true
  alias MedEx.Wire.FrameV1

  @hex "4d455831010000300000000200000003ffffffff0000000000000007002000000000000100000004000000080000000000fcffff00000004"

  test "independent 48-byte vector preserves uint64 and unknown configuration" do
    bytes = Base.decode16!(@hex, case: :lower)
    assert byte_size(bytes) == 56
    assert {:ok, f} = FrameV1.decode(bytes)
    assert f.stream_number == 2 and f.source_epoch == 3 and f.sequence == 7
    assert f.first_sample == 9_007_199_254_740_993 and f.config_epoch == :unknown

    assert f.payload ==
             <<-1024::little-signed-16, -1::little-signed-16, 0::little-signed-16,
               1024::little-signed-16>>

    assert {:ok, ^bytes} = FrameV1.encode(f)
    assert {:ok, known_zero} = FrameV1.encode(%{f | config_epoch: 0})
    assert binary_part(known_zero, 16, 4) == <<0, 0, 0, 0>>
  end

  test "rejects foreign magic, flags, truncation, trailing bytes and overflow" do
    bytes = Base.decode16!(@hex, case: :lower)

    for bad <- [
          "MF03" <> binary_part(bytes, 4, 52),
          binary_part(bytes, 0, 5) <> <<1>> <> binary_part(bytes, 6, 50),
          binary_part(bytes, 0, 55),
          bytes <> <<0>>
        ] do
      assert {:error, _} = FrameV1.decode(bad)
    end

    {:ok, f} = FrameV1.decode(bytes)
    assert {:error, _} = FrameV1.encode(%{f | first_sample: 0xFFFFFFFFFFFFFFFF})
    assert {:error, _} = FrameV1.encode(%{f | payload: :binary.copy(<<0>>, 65_537)})
  end
end
