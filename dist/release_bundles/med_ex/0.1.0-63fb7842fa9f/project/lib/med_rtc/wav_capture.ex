defmodule MedRTC.WavCapture do
  @moduledoc """
  Pure-Elixir 16-bit PCM WAV parser and one-input / two-output clinical capture
  runner.

  Streams chunks from a real WAV recording (such as a PhysioNet CirCor
  DigiScope phonocardiogram) to two independent outputs:

  1. An optional live preview callback (which may drop or reconnect with a
     browser/WebRTC peer mid-capture).
  2. An independent lossless PCM collector that computes the exact decoded
     sample count, duration, SHA-256 digest, and continuity state
     (`:observed_continuous | :observed_gap | :unknown`) for `MedCore.Session`.
  """

  alias MedCore.Session

  @type parsed_wav :: %{
          required(:channels) => pos_integer(),
          required(:sample_rate_hz) => pos_integer(),
          required(:bits_per_sample) => pos_integer(),
          required(:sample_count) => non_neg_integer(),
          required(:duration_ms) => non_neg_integer(),
          required(:pcm) => binary()
        }

  @type capture_summary :: %{
          required(:acquisition_id) => String.t(),
          required(:sample_rate_hz) => pos_integer(),
          required(:sample_count) => non_neg_integer(),
          required(:duration_ms) => non_neg_integer(),
          required(:artifact_sha256) => String.t(),
          required(:interval_ms) => {non_neg_integer(), non_neg_integer()},
          required(:continuity) => Session.continuity_state(),
          required(:preview_chunks_sent) => non_neg_integer(),
          required(:preview_chunks_dropped) => non_neg_integer()
        }

  @doc """
  Parses an uncompressed PCM WAV binary (handling arbitrary RIFF chunks before
  `fmt ` and `data`, as emitted by clinical recorders and PhysioNet CirCor).
  """
  @spec parse_wav(binary()) :: {:ok, parsed_wav()} | {:error, term()}
  def parse_wav(<<"RIFF", _size::little-32, "WAVE", rest::binary>>) do
    with {:ok, fmt, pcm} <- scan_chunks(rest, nil, nil) do
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
      when is_binary(pcm) and is_integer(sample_rate_hz) and sample_rate_hz > 0 do
    channels = 1
    bits_per_sample = 16
    byte_rate = sample_rate_hz * channels * div(bits_per_sample, 8)
    block_align = channels * div(bits_per_sample, 8)
    data_size = byte_size(pcm)
    riff_size = 36 + data_size

    header =
      <<"RIFF", riff_size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
        channels::little-16, sample_rate_hz::little-32, byte_rate::little-32,
        block_align::little-16, bits_per_sample::little-16, "data", data_size::little-32>>

    IO.iodata_to_binary([header, pcm])
  end

  @doc """
  Replays a parsed WAV through one input into two independent outputs:
  a live preview sink (`:on_preview_chunk`) and a lossless capture collector.

  Options:
  - `:acquisition_id` (required)
  - `:started_at_ms` (default `0`)
  - `:chunk_ms` (default `20`)
  - `:on_preview_chunk` (`fn chunk_idx, pcm_chunk -> :ok | {:error, term()} end`, optional)
  - `:drop_capture_indices` (`MapSet` or list of chunk indices simulating real capture loss)
  - `:continuity_observable?` (default `true`; when `false`, reports `:unknown`)
  """
  @spec replay(parsed_wav(), keyword()) :: capture_summary()
  def replay(%{pcm: pcm, sample_rate_hz: sr, channels: ch, bits_per_sample: bps} = wav, opts) do
    acq_id = Keyword.fetch!(opts, :acquisition_id)
    started_at_ms = Keyword.get(opts, :started_at_ms, 0)
    chunk_ms = Keyword.get(opts, :chunk_ms, 20)
    on_preview = Keyword.get(opts, :on_preview_chunk, fn _idx, _chunk -> :ok end)
    drop_capture = opts |> Keyword.get(:drop_capture_indices, []) |> MapSet.new()
    observable? = Keyword.get(opts, :continuity_observable?, true)

    bytes_per_frame = ch * div(bps, 8)
    chunk_bytes = max(1, div(sr * chunk_ms, 1000)) * bytes_per_frame
    chunks = chunk_binary(pcm, chunk_bytes)

    {captured_iodata, sent_preview, dropped_preview, capture_gaps} =
      chunks
      |> Enum.with_index()
      |> Enum.reduce({[], 0, 0, 0}, fn {chunk, idx}, {acc_cap, sent, dropped, gaps} ->
        {sent2, dropped2} =
          case on_preview.(idx, chunk) do
            :ok -> {sent + 1, dropped}
            _ -> {sent, dropped + 1}
          end

        if MapSet.member?(drop_capture, idx) do
          {acc_cap, sent2, dropped2, gaps + 1}
        else
          {[chunk | acc_cap], sent2, dropped2, gaps}
        end
      end)

    captured_pcm = captured_iodata |> Enum.reverse() |> IO.iodata_to_binary()
    captured_samples = div(byte_size(captured_pcm), bytes_per_frame)

    continuity =
      cond do
        not observable? -> :unknown
        capture_gaps > 0 -> :observed_gap
        true -> :observed_continuous
      end

    %{
      acquisition_id: acq_id,
      sample_rate_hz: sr,
      sample_count: captured_samples,
      duration_ms: wav.duration_ms,
      artifact_sha256: :crypto.hash(:sha256, captured_pcm) |> Base.encode16(case: :lower),
      interval_ms: {started_at_ms, started_at_ms + wav.duration_ms},
      continuity: continuity,
      preview_chunks_sent: sent_preview,
      preview_chunks_dropped: dropped_preview
    }
  end

  defp scan_chunks(<<>>, fmt, pcm) when not is_nil(fmt) and not is_nil(pcm), do: {:ok, fmt, pcm}
  defp scan_chunks(<<>>, _fmt, _pcm), do: {:error, :incomplete_wav_chunks}

  defp scan_chunks(<<id::binary-4, size::little-32, rest::binary>>, fmt, pcm)
       when byte_size(rest) >= size do
    pad = rem(size, 2)
    <<body::binary-size(^size), tail::binary>> = rest

    next_rest =
      if pad == 1 and byte_size(tail) > 0,
        do: binary_part(tail, 1, byte_size(tail) - 1),
        else: tail

    case id do
      "fmt " ->
        case parse_fmt(body) do
          {:ok, parsed_fmt} -> scan_chunks(next_rest, parsed_fmt, pcm)
          error -> error
        end

      "data" ->
        scan_chunks(next_rest, fmt, body)

      _other ->
        scan_chunks(next_rest, fmt, pcm)
    end
  end

  defp scan_chunks(_other, _fmt, _pcm), do: {:error, :truncated_wav_chunk}

  defp parse_fmt(
         <<1::little-16, channels::little-16, sample_rate_hz::little-32, _byte_rate::little-32,
           _block_align::little-16, bits_per_sample::little-16, _extra::binary>>
       )
       when channels > 0 and sample_rate_hz > 0 and bits_per_sample in [8, 16, 24, 32] do
    {:ok,
     %{
       channels: channels,
       sample_rate_hz: sample_rate_hz,
       bits_per_sample: bits_per_sample
     }}
  end

  defp parse_fmt(_other), do: {:error, :unsupported_wav_format}

  defp chunk_binary(<<>>, _size), do: []

  defp chunk_binary(bin, size) when byte_size(bin) <= size, do: [bin]

  defp chunk_binary(bin, size) do
    <<head::binary-size(^size), tail::binary>> = bin
    [head | chunk_binary(tail, size)]
  end
end
