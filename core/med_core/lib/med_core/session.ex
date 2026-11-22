defmodule MedCore.Session do
  @moduledoc """
  Immutable live clinical transport session aggregate and pure reducer seam.

  A `Session` owns live participants, WebRTC connection attempts, signal
  integrity state, device capture continuity, and control interlocks. It can
  outlast individual browser peer connections (`connection_id`) and supports
  standalone capture (`acquisition_id`) with or without an external clinical
  `encounter_ref`.
  """

  alias MedCore.Profile
  alias MedCore.StreamSpec

  @type session_id :: String.t()
  @type encounter_ref :: String.t() | nil
  @type connection_id :: String.t()
  @type acquisition_id :: String.t()

  @type integrity_subject ::
          {:preview_stream, String.t()}
          | {:recording_artifact, acquisition_id()}

  @type continuity_state :: :observed_continuous | :observed_gap | :unknown

  @type integrity_report :: %{
          required(:subject) => integrity_subject(),
          required(:interval_ms) => {non_neg_integer(), non_neg_integer()},
          required(:continuity) => continuity_state(),
          optional(:reasons) => [atom()]
        }

  @type integrity_status :: :unverified | :validated | {:degraded, [atom()]}

  @type degradation_level ::
          :nominal
          | :conserve_video
          | :audio_and_telemetry_only
          | :critical_telemetry_only

  @type t :: %__MODULE__{
          id: session_id(),
          encounter_ref: encounter_ref(),
          topology: Profile.topology(),
          streams: %{String.t() => StreamSpec.t()},
          participants: %{String.t() => map()},
          connections: %{connection_id() => map()},
          acquisitions: %{acquisition_id() => map()},
          integrity_state: %{integrity_subject() => integrity_status()},
          degradation_level: degradation_level(),
          audit_seq: non_neg_integer()
        }

  @enforce_keys [:id, :topology, :streams]
  defstruct [
    :id,
    :topology,
    :streams,
    encounter_ref: nil,
    participants: %{},
    connections: %{},
    acquisitions: %{},
    integrity_state: %{},
    degradation_level: :nominal,
    audit_seq: 0
  ]
end
