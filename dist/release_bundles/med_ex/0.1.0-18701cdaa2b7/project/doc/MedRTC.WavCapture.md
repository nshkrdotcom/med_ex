# `MedRTC.WavCapture`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/v0.1.0/lib/med_rtc/wav_capture.ex#L1)

Pure-Elixir 16-bit PCM WAV parser and one-input / two-output clinical capture
runner.

Streams chunks from a real WAV recording (such as a PhysioNet CirCor
DigiScope phonocardiogram) to two independent outputs:

1. An optional live preview callback (which may drop or reconnect with a
   browser/WebRTC peer mid-capture).
2. An independent lossless PCM collector that computes the exact decoded
   sample count, duration, SHA-256 digest, and continuity state
   (`:observed_continuous | :observed_gap | :unknown`) for `MedCore.Session`.

# `parsed_wav`

```elixir
@type parsed_wav() :: %{
  channels: pos_integer(),
  sample_rate_hz: pos_integer(),
  bits_per_sample: pos_integer(),
  sample_count: non_neg_integer(),
  duration_ms: non_neg_integer(),
  pcm: binary()
}
```

# `encode_pcm16_wav`

```elixir
@spec encode_pcm16_wav(binary(), pos_integer()) :: binary()
```

Encodes raw 16-bit signed little-endian mono PCM into a standard RIFF/WAVE
binary.

# `parse_wav`

```elixir
@spec parse_wav(binary()) :: {:ok, parsed_wav()} | {:error, term()}
```

Parses an uncompressed PCM WAV binary (handling arbitrary RIFF chunks before
`fmt ` and `data`, as emitted by clinical recorders and PhysioNet CirCor).

# `record`

```elixir
@spec record(Path.t(), Path.t(), Path.t(), keyword()) ::
  {:ok, map()} | {:error, term()}
```

Paces a verified WAV fixture and atomically finalizes its original PCM in
a playable WAV. The paired Ogg file contains 20 ms Opus frames derived from
the same input. Preview is best-effort and can stall or fail independently.

Run this operation in the acquisition task. Supply `:on_preview_frame`
to receive `(frame_index, opus_payload)` from the preview worker.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
