defmodule MedEx.Capture.FrameRules do
  @moduledoc false

  @frame_bytes 1_920
  @max_samples 48_000 * 60 * 30

  def advance(count, false, index, pcm)
      when index === count and is_binary(pcm) and byte_size(pcm) in 2..@frame_bytes and
             rem(byte_size(pcm), 2) == 0 and count + div(byte_size(pcm), 2) <= @max_samples do
    {:ok, count + div(byte_size(pcm), 2), byte_size(pcm) < @frame_bytes}
  end

  def advance(_count, _tail?, _index, _pcm), do: :error
end
