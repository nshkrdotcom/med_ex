defmodule MedCore.StreamSpec do
  @moduledoc """
  Declarative contract for a clinical media, telemetry, or device control stream.
  """

  @type archetype ::
          :diagnostic_audio
          | :telemetry
          | :control
          | :interactive_media
          | :voice_ai

  @type integrity_policy :: %{
          required(:require_dsp_disabled) => boolean(),
          required(:max_packet_loss_pct) => float(),
          required(:max_jitter_ms) => non_neg_integer(),
          required(:allow_plc) => boolean(),
          required(:sample_rate_hz) => pos_integer()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          archetype: archetype(),
          modality: atom(),
          codec_profile: term(),
          integrity_policy: integrity_policy(),
          priority: non_neg_integer()
        }

  @enforce_keys [:id, :archetype, :modality, :codec_profile, :integrity_policy]
  defstruct [
    :id,
    :archetype,
    :modality,
    :codec_profile,
    :integrity_policy,
    priority: 3
  ]
end
