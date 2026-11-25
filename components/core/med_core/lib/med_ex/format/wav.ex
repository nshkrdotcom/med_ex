defmodule MedEx.Format.Wav do
  @moduledoc "Header layout for canonical MedEx PCM WAV files."

  @header_size 44
  @sample_rate_hz 48_000
  @sample_bytes 2
  @byte_rate @sample_rate_hz * @sample_bytes
  @max_pcm_bytes @byte_rate * 60 * 30

  @doc "Returns the canonical WAV header length in bytes."
  @spec header_size() :: 44
  def header_size, do: @header_size

  @doc """
  Parses exactly the first `header_size/0` bytes and checks the total file size.

  The canonical format is mono 48 kHz PCM16LE with a fixed `fmt ` chunk and
  a nonempty `data` chunk of complete samples, up to 30 minutes. The RIFF
  and data lengths must describe the entire file, including its header.

  The returned layout describes the declared PCM payload. Reading and
  authenticating the payload belongs to the caller.
  """
  @spec parse_header(binary(), non_neg_integer()) ::
          {:ok,
           %{
             pcm_bytes: pos_integer(),
             sample_count: pos_integer(),
             sample_rate_hz: 48_000
           }}
          | {:error, :invalid_wav}
  def parse_header(
        <<"RIFF", riff_size::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
          @sample_rate_hz::little-32, @byte_rate::little-32, @sample_bytes::little-16,
          16::little-16, "data", pcm_bytes::little-32>>,
        file_size
      )
      when pcm_bytes in @sample_bytes..@max_pcm_bytes and rem(pcm_bytes, @sample_bytes) == 0 and
             file_size === pcm_bytes + @header_size and riff_size == file_size - 8 do
    {:ok,
     %{
       pcm_bytes: pcm_bytes,
       sample_count: div(pcm_bytes, @sample_bytes),
       sample_rate_hz: @sample_rate_hz
     }}
  end

  def parse_header(_, _), do: {:error, :invalid_wav}

  @doc false
  def header(data_size, sample_rate_hz) do
    <<"RIFF", @header_size - 8 + data_size::little-32, "WAVEfmt ", 16::little-32, 1::little-16,
      1::little-16, sample_rate_hz::little-32, sample_rate_hz * @sample_bytes::little-32,
      @sample_bytes::little-16, 16::little-16, "data", data_size::little-32>>
  end
end
