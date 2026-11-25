defmodule MedEx.Evidence do
  @moduledoc """
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
  """

  @enforce_keys ~w(acquisition_id artifact_key file_sha256 pcm_sha256 end_sample)a
  defstruct @enforce_keys ++
              [
                kind: :audio_pcm16_wav,
                sample_rate_hz: 48_000,
                first_sample: 0,
                sample_count: 0,
                continuity: :observed_continuous
              ]

  @type t :: %__MODULE__{
          acquisition_id: String.t(),
          artifact_key: String.t(),
          file_sha256: String.t(),
          pcm_sha256: String.t(),
          kind: :audio_pcm16_wav,
          sample_rate_hz: pos_integer(),
          first_sample: non_neg_integer(),
          end_sample: non_neg_integer(),
          sample_count: non_neg_integer(),
          continuity: :observed_continuous
        }
end
