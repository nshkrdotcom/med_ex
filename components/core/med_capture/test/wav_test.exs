defmodule MedEx.FormatWavTest do
  use ExUnit.Case, async: true
  alias MedEx.Format.Wav

  test "descriptor-derived PCM headers preserve rate, channel count and exact alignment" do
    for {encoding, bits} <- [s16le: 16, s24le: 24, s32le: 32],
        rate <- [250, 8000, 44_100, 48_000],
        channels <- [1, 2, 8] do
      align = div(bits, 8) * channels
      bytes = align * 17

      assert {:ok,
              <<"RIFF", riff::little-32, "WAVEfmt ", 16::little-32, 1::little-16,
                ^channels::little-16, ^rate::little-32, byte_rate::little-32, ^align::little-16,
                ^bits::little-16, "data", ^bytes::little-32>>} =
               Wav.header(encoding, channels, rate, bytes)

      assert riff == 36 + bytes and byte_rate == rate * align
    end
  end

  test "invalid encoding, alignment, widths, rate and RIFF overflow are refused" do
    for args <- [
          [:float, 1, 48_000, 2],
          [:s16le, 0, 48_000, 2],
          [:s16le, 1, 0, 2],
          [:s16le, 2, 48_000, 3],
          [:s16le, 1, 0xFFFFFFFF, 2],
          [:s32le, 65_535, 1, 4],
          [:s16le, 1, 48_000, 0xFFFFFFFF],
          [:s16le, 1, 48_000.0, 2]
        ] do
      assert {:error, :invalid_wav_projection} = apply(Wav, :header, args)
    end
  end
end
