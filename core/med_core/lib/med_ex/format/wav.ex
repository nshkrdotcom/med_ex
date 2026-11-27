defmodule MedEx.Format.Wav do
  @moduledoc "Pure RIFF header projection for a verified contiguous PCM segment."
  @spec header(:s16le | :s24le | :s32le, pos_integer(), pos_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :invalid_wav_projection}
  def header(encoding, channels, rate, bytes)
      when encoding in [:s16le, :s24le, :s32le] and is_integer(channels) and channels in 1..65_535 and
             is_integer(rate) and rate in 1..0xFFFFFFFF and is_integer(bytes) and
             bytes in 0..0xFFFFFFDB do
    pcm_header(MedEx.StreamSpec.bytes_per_value(encoding), channels, rate, bytes)
  end

  def header(_, _, _, _), do: {:error, :invalid_wav_projection}

  defp pcm_header(width, channels, rate, bytes) do
    align = channels * width

    if align <= 65_535 and rate * align <= 0xFFFFFFFF and rem(bytes, align) == 0 do
      {:ok,
       <<"RIFF", 36 + bytes::little-32, "WAVEfmt ", 16::little-32, 1::little-16,
         channels::little-16, rate::little-32, rate * align::little-32, align::little-16,
         width * 8::little-16, "data", bytes::little-32>>}
    else
      {:error, :invalid_wav_projection}
    end
  end
end
