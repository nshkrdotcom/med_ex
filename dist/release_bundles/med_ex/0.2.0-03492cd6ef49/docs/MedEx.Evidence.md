# `MedEx.Evidence`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/med_ex-v0.2.0/lib/med_ex/evidence.ex#L1)

Finalized evidence returned by `MedEx.Capture.finish/1` for a continuous mono
48 kHz PCM16LE WAV acquisition.

## Fields

  * `:acquisition_id` — host-supplied acquisition correlation identifier.
  * `:artifact_key` — content-addressed filename (`"<file_sha256>.wav"`).
  * `:file_sha256` — lowercase hex SHA-256 of the complete finalized WAV file.
  * `:pcm_sha256` — lowercase hex SHA-256 of the raw PCM16LE payload bytes.
  * `:kind` — modality discriminator (`:audio_pcm16_wav`).
  * `:sample_rate_hz` — audio sample rate in Hz (`48_000`).
  * `:first_sample` — inclusive starting sample index (`0`).
  * `:end_sample` — exclusive ending sample index.
  * `:sample_count` — total captured mono samples.
  * `:continuity` — observed source continuity verdict (`:observed_continuous`).

# `t`

```elixir
@type t() :: %MedEx.Evidence{
  acquisition_id: String.t(),
  artifact_key: String.t(),
  continuity: :observed_continuous,
  end_sample: non_neg_integer(),
  file_sha256: String.t(),
  first_sample: non_neg_integer(),
  kind: :audio_pcm16_wav,
  pcm_sha256: String.t(),
  sample_count: non_neg_integer(),
  sample_rate_hz: pos_integer()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
