defmodule MedCore.Encounter do
  @moduledoc """
  Immutable clinical encounter aggregate and pure reducer seam (`step/2`).
  """

  alias MedCore.Profile
  alias MedCore.StreamSpec

  @type integrity_status :: :unverified | :validated | {:degraded, [atom()]}
  @type degradation_level ::
          :nominal
          | :conserve_video
          | :audio_and_telemetry_only
          | :critical_telemetry_only

  @type t :: %__MODULE__{
          id: String.t(),
          topology: Profile.topology(),
          streams: %{String.t() => StreamSpec.t()},
          participants: %{String.t() => map()},
          integrity_state: %{String.t() => integrity_status()},
          degradation_level: degradation_level(),
          audit_seq: non_neg_integer()
        }

  @enforce_keys [:id, :topology, :streams]
  defstruct [
    :id,
    :topology,
    :streams,
    participants: %{},
    integrity_state: %{},
    degradation_level: :nominal,
    audit_seq: 0
  ]
end
