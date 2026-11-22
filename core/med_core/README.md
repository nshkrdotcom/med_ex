<p align="center">
  <img src="assets/med_core.svg" width="200" height="200" alt="MedCore logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex">
    <img alt="GitHub: med_ex" src="https://img.shields.io/badge/GitHub-med_ex-0b0f14?logo=github" />
  </a>
  <a href="LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# MedCore

`med_core` is the **pure functional core** of the [MedEx](../../README.md) framework.

It contains **zero `GenServer`s, zero WebRTC/network calls, zero filesystem I/O, and zero wall-clock reads** (monotonic timestamps are passed in explicitly as fields on immutable events). Every clinical decision is a deterministic transition `{next_encounter, effects} = MedCore.Encounter.step(encounter, event)`.

---

## Why a Pure Functional Core Matters for Medical Software

FDA SaMD and IEC 62304 verification demand deterministic traceability of safety-critical state transitions:

- Proving that diagnostic audio packet loss above `0.05%` immediately flags the affected span as `:non_diagnostic` and suppresses advisory AI scoring.
- Proving that an unauthenticated or non-clinician peer cannot mutate hardware stethoscope gain or hearing-aid DSP parameters.
- Proving that 15 ppm clock drift or out-of-order telemetry bursts do not corrupt multi-stream ECG/auscultation alignment.

Because `med_core` emits plain declarative effects instead of performing side effects directly, recorded clinical encounters can be exhaustively property-tested and replayed deterministically with zero UDP sockets, zero browsers, and zero flaky timers.

---

## Core Data Contracts

### `MedCore.StreamSpec`

Declarative contract for every clinical media, telemetry, or control stream across the 4 transport archetypes:

```elixir
%MedCore.StreamSpec{
  id: "auscultation",
  archetype: :diagnostic_audio,          # :diagnostic_audio | :telemetry | :control | :interactive_media | :voice_ai
  modality: :stethoscope,                # :stethoscope | :ecg | :spo2 | :ultrasound | :voice | :respiratory
  codec_profile: {:pcm_s16le, 4_000},    # {:pcm_s16le, hz} | {:opus, opts} | {:binary_frame, mod} | {:cbor_signed, mod}
  priority: 2,                           # 0 (control) > 1 (telemetry) > 2 (diagnostic) > 3 (talkback) > 4 (video)
  integrity_policy: %{
    require_dsp_disabled: true,          # AEC=false, NS=false, AGC=false
    max_packet_loss_pct: 0.05,
    max_jitter_ms: 40,
    allow_plc: false,                    # Packet Loss Concealment disallowed on diagnostic audio
    sample_rate_hz: 4_000
  }
}
```

### `MedCore.Encounter`

Immutable aggregate owning the complete clinical state of a live session:

- `id` — Unique encounter identifier
- `topology` — `:server_terminated | :sfu | :hybrid`
- `streams` — `%{stream_id => %MedCore.StreamSpec{}}`
- `participants` — `%{peer_id => %{role: :patient | :clinician | :device | :ai, ...}}`
- `clock_anchor` — `%MedCore.TimelineAligner{}` mapping hardware sample counters and RTP timestamps to canonical `encounter_t_ms`
- `integrity_state` — `%{stream_id => :unverified | :validated | {:degraded, [atom()]}}`
- `control_interlock` — `%MedCore.ControlInterlock{}` tracking exclusive control leases, pending nonces, and safe-fallback state
- `degradation_level` — `:nominal | :conserve_video | :audio_and_telemetry_only | :critical_telemetry_only`
- `audit_seq` & `audit_head_hash` — Hash-chain state for tamper-evident audit logging

### `MedCore.Profile`

Behaviour implemented by product apps (such as [`apps/med_pulse`](../../apps/med_pulse/README.md)) to compose clinical transport archetypes without touching low-level WebRTC plumbing:

- `topology/0` — Declares `:server_terminated`, `:sfu`, or `:hybrid`
- `streams/0` — Returns `[%MedCore.StreamSpec{}]`
- `inference_hooks/0` — Declares sliding-window analysis hooks gated by `integrity_state == :validated`
- `control_policy/0` — Returns the module defining parameter bounds and RBAC rules for actuated devices

---

## The 5 Pure Clinical State Machines

| Module | Responsibility | Key Emitted Effects |
| --- | --- | --- |
| `MedCore.SignalIntegrity` | Evaluates client `MediaStreamTrack.getSettings()` DSP-off attestations (`echoCancellation`, `noiseSuppression`, `autoGainControl`), RTCP `remote-inbound-rtp` loss, jitter, and PCM clipping ratios. Transitions streams across `:unverified` → `:validated` ↔ `{:degraded, reasons}`. | `{:publish_ui, :integrity, ...}`, `{:tag_archive_span, :non_diagnostic, t0..t1}` |
| `MedCore.TimelineAligner` | Maintains a pure linear-regression / median-offset clock model per participant (`hardware_sample_idx` / `rtp_timestamp` ↔ `encounter_t_ms`) with explicit `uncertainty_ms` and exact monotonic sample-gap detection. | Annotated canonical timestamps on telemetry, audio clips, and inference results |
| `MedCore.ControlInterlock` | Two-phase, role-authorized command FSM enforcing clinician RBAC, exclusive control leases, parameter bounds, nonce idempotency, and deadman ACK deadlines with automatic `:safe_fallback`. | `{:rtc_send_datachannel, peer, :control, cmd}`, `{:schedule_timeout, {:cmd_ack, nonce}, ms}`, `{:append_audit_log, record}` |
| `MedCore.DegradationPolicy` | Consumes RTCP/TWCC bandwidth and loss snapshots and applies priority-ordered media adaptation so clinician talking-head video never starves diagnostic audio or ECG telemetry. | `{:rtc_set_simulcast_layer, peer, :low}`, `{:rtc_pause_track, peer, track_id}` |
| `MedCore.AuditChain` | Produces deterministic SHA-256 hash-chained audit records (`prev_hash`, `seq`, `actor`, `action`, `payload_sha256`, `encounter_t_ms`) for joins, captures, AI advisory displays, and device control commands. | `{:append_audit_log, %AuditRecord{}}` |

---

## Planned Module Layout

```text
core/med_core/lib/
├── med_core.ex
└── med_core/
    ├── stream_spec.ex
    ├── encounter.ex
    ├── profile.ex
    ├── event.ex
    ├── effect.ex
    ├── signal_integrity.ex
    ├── timeline_aligner.ex
    ├── control_interlock.ex
    ├── degradation_policy.ex
    └── audit_chain.ex
```

## Phase 1A Verification Plan

When implementation begins, `med_core` will be verified via deterministic trace replay and property-based tests covering:

1. Diagnostic auscultation packet loss crossing `0.05%` → span tagged `:non_diagnostic` and advisory AI output suppressed.
2. Sustained `15 ppm` clock drift between ECG (250 Hz) and stethoscope (4 kHz) → aligned offset error bounded `< 10 ms`.
3. Concurrent control commands from two clinicians + dropped device ACK → strict mutual exclusion and `:safe_fallback` timeout.

## Related Packages

- [MedEx Workspace Overview](../../README.md)
- [MedRTC (OTP Effect Runtime)](../med_rtc/README.md)
- [MedAdapters (Clinical OSS Ports)](../med_adapters/README.md)
- [MedWeb (LiveView Workbench)](../med_web/README.md)
- [MedPulse (First Reference App)](../../apps/med_pulse/README.md)
