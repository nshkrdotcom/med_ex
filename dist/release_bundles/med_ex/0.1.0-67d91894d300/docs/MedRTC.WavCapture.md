# `MedRTC.WavCapture`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/med_ex-v0.1.0/lib/med_rtc/wav_capture.ex#L1)

Replays a finite mono PCM16 WAV and its prepared 20 ms Opus preview.
Recording integrity describes the retained file payload. Each final artifact
is identified by its canonical WAV digest and its decoded PCM digest.

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
