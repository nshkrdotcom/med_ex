# `MedCore.Session`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/v0.1.0/lib/med_core/session.ex#L1)

Immutable live clinical transport session aggregate and pure reducer (`step/2`).

A `Session` owns live participants, WebRTC connection attempts (`connection_id`),
transient preview interruptions, independent recording continuity, and device
acquisitions (`acquisition_id`). It can outlast individual browser reconnects
and supports standalone capture with `encounter_ref: nil` and no connected peer.

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

# `effect`

```elixir
@type effect() ::
  {:emit_fact, atom(), map()}
  | {:publish_ui, atom(), map()}
  | {:start_lossless_capture, String.t(), acquisition_id()}
  | {:append_audit_log, map()}
```

# `encounter_ref`

```elixir
@type encounter_ref() :: String.t() | nil
```

# `event`

```elixir
@type event() ::
  {:peer_connected,
   %{
     :peer_id =&gt; String.t(),
     :connection_id =&gt; connection_id(),
     :role =&gt; atom(),
     :t_ms =&gt; non_neg_integer(),
     optional(:stream_id) =&gt; String.t()
   }}
  | {:peer_disconnected,
     %{
       :peer_id =&gt; String.t(),
       :connection_id =&gt; connection_id(),
       :t_ms =&gt; non_neg_integer(),
       optional(:stream_id) =&gt; String.t()
     }}
  | {:acquisition_started,
     %{
       acquisition_id: acquisition_id(),
       stream_id: String.t(),
       t_ms: non_neg_integer()
     }}
  | {:capture_completed,
     %{
       acquisition_id: acquisition_id(),
       artifact_sha256: String.t(),
       interval_ms: {non_neg_integer(), non_neg_integer()},
       continuity: continuity_state(),
       delivery_id: String.t(),
       t_ms: non_neg_integer()
     }}
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
  integrity_reports: %{required(integrity_subject()) =&gt; integrity_report()},
  integrity_state: %{required(integrity_subject()) =&gt; integrity_status()},
  participants: %{required(String.t()) =&gt; map()},
  preview_interruptions: [map()],
  streams: %{required(String.t()) =&gt; MedCore.StreamSpec.t()},
  topology: MedCore.Profile.topology()
}
```

# `new`

```elixir
@spec new(keyword()) :: t()
```

Constructs a new live clinical session. `encounter_ref` is optional (`nil` for standalone capture).

# `step`

```elixir
@spec step(t(), event()) :: {t(), [effect()]}
```

Pure state transition function `{next_session, effects} = step(session, event)`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
