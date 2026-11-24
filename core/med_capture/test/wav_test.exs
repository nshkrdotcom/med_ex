defmodule MedEx.WavTest do
  use ExUnit.Case, async: true

  alias MedEx.Wav

  test "parses the fixed layout, including the smallest supported PCM payload" do
    assert Wav.header_size() == 44

    assert {:ok, %{pcm_bytes: 2, sample_count: 1, sample_rate_hz: 48_000}} =
             Wav.parse_header(canonical_header(2), 46)

    assert Wav.header(2, 48_000) == canonical_header(2)
  end

  test "accepts up to 30 minutes of audio at the full sample rate" do
    assert {:ok, %{pcm_bytes: 172_800_000, sample_count: 86_400_000, sample_rate_hz: 48_000}} =
             Wav.parse_header(canonical_header(172_800_000), 172_800_044)

    assert {:error, :invalid_wav} =
             Wav.parse_header(canonical_header(172_800_002), 172_800_046)
  end

  test "rejects headers with unsupported encoding or layout fields" do
    header = canonical_header(2)

    for {offset, replacement} <- [
          {0, "RF64"},
          {4, <<39::little-32>>},
          {8, "FAKE"},
          {12, "JUNK"},
          {16, <<18::little-32>>},
          {20, <<3::little-16>>},
          {22, <<2::little-16>>},
          {24, <<44_100::little-32>>},
          {28, <<48_000::little-32>>},
          {32, <<4::little-16>>},
          {34, <<8::little-16>>},
          {36, "LIST"},
          {40, <<4::little-32>>}
        ] do
      tail_offset = offset + byte_size(replacement)

      malformed =
        binary_part(header, 0, offset) <>
          replacement <>
          binary_part(header, tail_offset, 44 - tail_offset)

      assert {:error, :invalid_wav} = Wav.parse_header(malformed, 46)
    end
  end

  test "requires exactly a header and a nonempty aligned payload of the declared size" do
    header = canonical_header(2)

    for {head, size} <- [
          {binary_part(header, 0, 43), 46},
          {header <> <<0>>, 46},
          {header, 45},
          {header, 47},
          {canonical_header(0), 44},
          {canonical_header(3), 47}
        ] do
      assert {:error, :invalid_wav} = Wav.parse_header(head, size)
    end
  end

  defp canonical_header(size) do
    <<"RIFF", size + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
      48_000::little-32, 96_000::little-32, 2::little-16, 16::little-16, "data", size::little-32>>
  end
end
