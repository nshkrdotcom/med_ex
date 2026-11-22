# `MedCore.Session`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/v0.1.0/lib/med_core/session.ex#L1)

Immutable live clinical transport session aggregate and pure reducer seam.

A `Session` owns live participants, WebRTC connection attempts, signal
integrity state, device capture continuity, and control interlocks. It can
outlast individual browser peer connections (`connection_id`) and supports
standalone capture (`acquisition_id`) with or without an external clinical
`encounter_ref`.

# `acquisition_id`

```elixir
@type acquisition_id() :: String.t()
```

# `connection_id`

```elixir
@type connection_id() :: String.t()
```

# `continuity_state`

```elixir
@type continuity_state() :: :observed_continuous | :observed_gap | :unknown
```

# `degradation_level`

```elixir
@type degradation_level() ::
  :nominal
  | :conserve_video
  | :audio_and_telemetry_only
  | :critical_telemetry_only
```

# `encounter_ref`

```elixir
@type encounter_ref() :: String.t() | nil
```

# `integrity_report`

```elixir
@type integrity_report() :: %{
  :subject =&gt; integrity_subject(),
  :interval_ms =&gt; {non_neg_integer(), non_neg_integer()},
  :continuity =&gt; continuity_state(),
  optional(:reasons) =&gt; [atom()]
}
```

# `integrity_status`

```elixir
@type integrity_status() :: :unverified | :validated | {:degraded, [atom()]}
```

# `integrity_subject`

```elixir
@type integrity_subject() ::
  {:preview_stream, String.t()} | {:recording_artifact, acquisition_id()}
```

# `session_id`

```elixir
@type session_id() :: String.t()
```

# `t`

```elixir
@type t() :: %MedCore.Session{
  acquisitions: %{required(acquisition_id()) =&gt; map()},
  audit_seq: non_neg_integer(),
  connections: %{required(connection_id()) =&gt; map()},
  degradation_level: degradation_level(),
  encounter_ref: encounter_ref(),
  id: session_id(),
  integrity_state: %{required(integrity_subject()) =&gt; integrity_status()},
  participants: %{required(String.t()) =&gt; map()},
  streams: %{required(String.t()) =&gt; MedCore.StreamSpec.t()},
  topology: MedCore.Profile.topology()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
