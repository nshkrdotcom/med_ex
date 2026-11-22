defmodule PulseScope.ClinicalProfile do
  @moduledoc """
  Declarative `MedCore.Profile` skeleton for PulseScope (#1 Stethoscope + #4 RPM).
  """

  @behaviour MedCore.Profile

  alias MedCore.StreamSpec

  @impl true
  def topology, do: :server_terminated

  @impl true
  def streams do
    [
      %StreamSpec{
        id: "auscultation",
        archetype: :diagnostic_audio,
        modality: :stethoscope,
        codec_profile: {:pcm_s16le, 4_000},
        priority: 2,
        integrity_policy: %{
          require_dsp_disabled: true,
          max_packet_loss_pct: 0.05,
          max_jitter_ms: 40,
          allow_plc: false,
          sample_rate_hz: 4_000
        }
      },
      %StreamSpec{
        id: "vitals_telemetry",
        archetype: :telemetry,
        modality: :ecg,
        codec_profile: {:binary_frame, PulseScope.VitalsFrame},
        priority: 1,
        integrity_policy: %{
          require_dsp_disabled: false,
          max_packet_loss_pct: 0.0,
          max_jitter_ms: 100,
          allow_plc: false,
          sample_rate_hz: 250
        }
      },
      %StreamSpec{
        id: "device_control",
        archetype: :control,
        modality: :stethoscope,
        codec_profile: {:cbor_signed, PulseScope.ControlSchema},
        priority: 0,
        integrity_policy: %{
          require_dsp_disabled: false,
          max_packet_loss_pct: 0.0,
          max_jitter_ms: 500,
          allow_plc: false,
          sample_rate_hz: 1
        }
      },
      %StreamSpec{
        id: "talkback_voice",
        archetype: :interactive_media,
        modality: :voice,
        codec_profile: {:opus, bitrate: 32_000, fec: true, dtx: true},
        priority: 3,
        integrity_policy: %{
          require_dsp_disabled: false,
          max_packet_loss_pct: 5.0,
          max_jitter_ms: 80,
          allow_plc: true,
          sample_rate_hz: 48_000
        }
      }
    ]
  end

  @impl true
  def inference_hooks do
    [
      {"auscultation", PulseScope.Adapters.OpenStethoscopeOrtex, window_ms: 8_000, hop_ms: 2_000},
      {"vitals_telemetry", PulseScope.Adapters.NeuroKitWorker, window_ms: 5_000, hop_ms: 1_000}
    ]
  end

  @impl true
  def control_policy, do: PulseScope.ControlPolicy
end
