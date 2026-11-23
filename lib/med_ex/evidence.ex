defmodule MedEx.Evidence do
  @moduledoc "Finalized evidence for a continuous mono PCM16 WAV acquisition."

  @enforce_keys ~w(acquisition_id artifact_key file_sha256 pcm_sha256 end_sample)a
  defstruct @enforce_keys ++
              [
                kind: :audio_pcm16_wav,
                sample_rate_hz: 48_000,
                first_sample: 0,
                sample_count: 0,
                continuity: :observed_continuous
              ]
end
