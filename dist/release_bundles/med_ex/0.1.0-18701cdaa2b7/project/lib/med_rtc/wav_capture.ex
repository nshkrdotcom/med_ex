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

  alias ExWebRTC.Media.Ogg.Reader

  @frame_ms 20

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
  Paces a verified WAV fixture and atomically finalizes its original PCM in
  a playable WAV. The paired Ogg file contains 20 ms Opus frames derived from
  the same input. Preview is best-effort and can stall or fail independently.

  Run this operation in the acquisition task. Supply `:on_preview_frame`
  to receive `(frame_index, opus_payload)` from the preview worker.
  """
  @spec record(Path.t(), Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def record(wav_path, opus_path, artifact_path, opts) do
    acquisition_id = Keyword.fetch!(opts, :acquisition_id)
    started_at_ms = Keyword.get(opts, :started_at_ms, 0)

    with {:ok, input} <- File.read(wav_path),
         {:ok, wav} <- parse_wav(input),
         :ok <- pace_recording(wav.duration_ms, opus_path, opts[:on_preview_frame]),
         :ok <- finalize_wav(artifact_path, wav) do
      {:ok,
       %{
         acquisition_id: acquisition_id,
         artifact_path: artifact_path,
         artifact_sha256: :crypto.hash(:sha256, wav.pcm) |> Base.encode16(case: :lower),
         sample_count: wav.sample_count,
         sample_rate_hz: wav.sample_rate_hz,
         duration_ms: wav.duration_ms,
         interval_ms: {started_at_ms, started_at_ms + wav.duration_ms},
         continuity: :observed_continuous
       }}
    end
  end

  defp pace_recording(duration_ms, opus_path, on_frame) do
    preview = start_preview(opus_path, on_frame)
    start = System.monotonic_time(:millisecond)
    frame_count = ceil(duration_ms / @frame_ms)

    try do
      Enum.each(0..(frame_count - 1)//1, fn index ->
        wait_until(start + index * @frame_ms)
        offer_frame(preview, index)
      end)

      wait_until(start + duration_ms)
    after
      if preview, do: Process.exit(preview, :kill)
    end
  end

  defp start_preview(_path, nil), do: nil

  defp start_preview(path, on_frame) when is_function(on_frame, 2) do
    spawn(fn ->
      with {:ok, reader} <- Reader.open(path) do
        preview_frames(reader, 0, on_frame)
      end
    end)
  end

  defp offer_frame(pid, index) when is_pid(pid) do
    if Process.info(pid, :message_queue_len) == {:message_queue_len, 0} do
      send(pid, {:preview_frame, index})
    end
  end

  defp offer_frame(nil, _index), do: :ok

  defp preview_frames(reader, index, on_frame) do
    receive do
      {:preview_frame, target} ->
        with {:ok, packet, reader} <- read_preview_frame(reader, index, target) do
          on_frame.(target, packet)
          preview_frames(reader, target + 1, on_frame)
        end
    after
      5_000 -> Reader.close(reader)
    end
  end

  defp read_preview_frame(reader, index, target) do
    case Reader.next_packet(reader) do
      {:ok, {packet, @frame_ms}, next} when index == target -> {:ok, packet, next}
      {:ok, {_packet, @frame_ms}, next} -> read_preview_frame(next, index + 1, target)
      _ -> :error
    end
  end

  defp wait_until(deadline) do
    Process.sleep(max(deadline - System.monotonic_time(:millisecond), 0))
  end

  defp finalize_wav(path, wav) do
    temp = path <> ".part-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      with :ok <- File.write(temp, encode_pcm16_wav(wav.pcm, wav.sample_rate_hz)),
           do: File.rename(temp, path)
    after
      File.rm(temp)
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
