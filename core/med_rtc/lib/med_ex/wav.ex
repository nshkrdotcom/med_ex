defmodule MedEx.Wav do
  @moduledoc false

  @type parsed_wav :: %{
          required(:channels) => pos_integer(),
          required(:sample_rate_hz) => pos_integer(),
          required(:bits_per_sample) => pos_integer(),
          required(:sample_count) => non_neg_integer(),
          required(:duration_ms) => non_neg_integer(),
          required(:pcm) => binary()
        }

  @doc """
  Parses an uncompressed PCM WAV binary (handling arbitrary RIFF chunks before
  `fmt ` and `data`, as emitted by clinical recorders and PhysioNet CirCor).
  """
  @spec parse_wav(binary()) :: {:ok, parsed_wav()} | {:error, term()}
  def parse_wav(<<"RIFF", size::little-32, "WAVE", rest::binary>>)
      when size == byte_size(rest) + 4 do
    with {:ok, fmt, pcm} <- scan_chunks(rest, nil, nil),
         :ok <- validate_pcm(pcm) do
      bytes_per_frame = fmt.channels * div(fmt.bits_per_sample, 8)
      sample_count = div(byte_size(pcm), bytes_per_frame)
      duration_ms = round(sample_count / fmt.sample_rate_hz * 1000)

      {:ok,
       %{
         channels: fmt.channels,
         sample_rate_hz: fmt.sample_rate_hz,
         bits_per_sample: fmt.bits_per_sample,
         sample_count: sample_count,
         duration_ms: duration_ms,
         pcm: pcm
       }}
    end
  end

  def parse_wav(_other), do: {:error, :invalid_wav_header}

  @doc """
  Encodes raw 16-bit signed little-endian mono PCM into a standard RIFF/WAVE
  binary.
  """
  @spec encode_pcm16_wav(binary(), pos_integer()) :: binary()
  def encode_pcm16_wav(pcm, sample_rate_hz)
      when is_binary(pcm) and rem(byte_size(pcm), 2) == 0 and is_integer(sample_rate_hz) and
             sample_rate_hz > 0 do
    IO.iodata_to_binary([header(byte_size(pcm), sample_rate_hz), pcm])
  end

  @doc false
  def header(data_size, sample_rate_hz) do
    <<"RIFF", 36 + data_size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      1::little-16, sample_rate_hz::little-32, sample_rate_hz * 2::little-32, 2::little-16,
      16::little-16, "data", data_size::little-32>>
  end

  @doc false
  def sync_directory(dir) do
    with {:ok, fd} <- :file.open(String.to_charlist(dir), [:read, :raw, :directory]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp validate_pcm(pcm) when byte_size(pcm) > 0 and rem(byte_size(pcm), 2) == 0, do: :ok
  defp validate_pcm(_pcm), do: {:error, :invalid_pcm_frames}

  defp scan_chunks(<<>>, fmt, pcm) when not is_nil(fmt) and not is_nil(pcm), do: {:ok, fmt, pcm}
  defp scan_chunks(<<>>, _fmt, _pcm), do: {:error, :incomplete_wav_chunks}

  defp scan_chunks(<<id::binary-4, size::little-32, rest::binary>>, fmt, pcm)
       when byte_size(rest) >= size + rem(size, 2) do
    pad = rem(size, 2)
    <<body::binary-size(^size), tail::binary>> = rest

    next_rest =
      if pad == 1 and byte_size(tail) > 0,
        do: binary_part(tail, 1, byte_size(tail) - 1),
        else: tail

    consume_chunk(id, body, next_rest, fmt, pcm)
  end

  defp scan_chunks(_other, _fmt, _pcm), do: {:error, :truncated_wav_chunk}

  defp consume_chunk(id, body, next_rest, fmt, pcm) do
    case id do
      "fmt " when not is_nil(fmt) ->
        {:error, :duplicate_format}

      "fmt " ->
        case parse_fmt(body) do
          {:ok, parsed_fmt} -> scan_chunks(next_rest, parsed_fmt, pcm)
          error -> error
        end

      "data" when not is_nil(pcm) ->
        {:error, :duplicate_data}

      "data" ->
        scan_chunks(next_rest, fmt, body)

      _other ->
        scan_chunks(next_rest, fmt, pcm)
    end
  end

  defp parse_fmt(
         <<1::little-16, 1::little-16, sample_rate_hz::little-32, byte_rate::little-32,
           2::little-16, 16::little-16, _extra::binary>>
       )
       when sample_rate_hz > 0 and byte_rate == sample_rate_hz * 2 do
    {:ok,
     %{
       channels: 1,
       sample_rate_hz: sample_rate_hz,
       bits_per_sample: 16
     }}
  end

  defp parse_fmt(_other), do: {:error, :unsupported_wav_format}
end
