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

It contains **zero `GenServer`s, zero WebRTC/network calls, zero filesystem I/O, and zero wall-clock reads** (monotonic timestamps are passed in explicitly as fields on immutable events). Every live-session decision is a deterministic transition `{next_session, effects}` produced by a pure `step/2` reducer.

---

## Why a Pure Functional Core Matters for Medical Software

FDA SaMD and IEC 62304 verification demand deterministic traceability of safety-critical state transitions:

- Proving that diagnostic audio packet loss above `0.05%` immediately flags the affected interval as `:non_diagnostic` and suppresses advisory AI scoring.
- Proving that an unauthenticated or non-clinician peer cannot mutate hardware stethoscope gain or hearing-aid DSP parameters.
- Proving that 15 ppm clock drift or out-of-order telemetry bursts do not corrupt multi-stream ECG/auscultation alignment.
- Proving that a clinician browser disconnect never corrupts or mislabels an independent device recording.

Because `med_core` emits plain declarative effects instead of performing side effects directly, recorded clinical sessions can be exhaustively property-tested and replayed deterministically with zero UDP sockets, zero browsers, and zero flaky timers.

---

## Ownership Boundary & Four-Level Identity Model

`med_ex` owns the **live clinical signal and WebRTC transport plane** (`MedCore.Session`). Durable clinical encounters, clinician observation acceptance, transactional outbox storage, and FHIR/HL7 delivery live outside `med_ex` (in `med_fabric`'s `mf_domain`, `mf_store`, and `mf_interop`).

`MedCore.Session` distinguishes four independent identities:

| Identifier | Owner | Lifetime & Standalone Rule |
| --- | --- | --- |
| `encounter_ref` *(optional)* | External clinical workflow (`med_fabric`) | Opaque correlation reference spanning sessions and reconnects. May be `nil` for standalone `med_ex` sessions or OEM capture. |
| `session_id` | `med_ex` (`MedCore.Session`) | Live real-time session owning streams, participants, integrity reports, and control leases. **Outlasts individual browser reconnects.** |
| `connection_id` | `med_ex` (`MedRTC` peer transport) | Single WebRTC peer-connection attempt within a session. A reconnecting browser creates a new `connection_id` inside the same `session_id`. |
| `acquisition_id` | Device / capture span | Identifies a specific lossless recording or sensor capture. Valid even when `encounter_ref` is `nil` or no clinician browser peer is currently connected. |

---

## Preview Integrity vs. Recording/Artifact Integrity

A drop on the clinician's live WebRTC preview is **not** the same fact as a gap in the device's lossless recording. Conflating the two can cause a UI to describe a complete recording as damaged—or an unmonitored, incomplete recording as sound.

Every integrity report emitted by `MedCore.SignalIntegrity` MUST declare three things:

1. **`subject`**: `{:preview_stream, stream_id}` **or** `{:recording_artifact, acquisition_id}`
2. **`interval_ms`**: `{t0_ms, t1_ms}` on the session's aligned timeline
3. **`continuity`**: `:observed_continuous | :observed_gap | :unknown` (explicitly distinguishing verified continuity, verified sample/packet loss, and unobserved intervals)

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

### `MedCore.Session`

Immutable aggregate owning the complete live state of a session:

- `id` (`session_id`) — Unique live session identifier
- `encounter_ref` — Optional external clinical encounter reference (`nil` in standalone mode)
- `topology` — `:server_terminated | :sfu | :hybrid`
- `streams` — `%{stream_id => %MedCore.StreamSpec{}}`
- `participants` — `%{peer_id => %{role: :patient | :clinician | :device | :ai, ...}}`
- `connections` — `%{connection_id => %{peer_id: ..., state: ...}}`
- `acquisitions` — `%{acquisition_id => %{state: :active | :completed | :aborted, ...}}`
- `integrity_state` — `%{integrity_subject => :unverified | :validated | {:degraded, [atom()]}}`
- `degradation_level` — `:nominal | :conserve_video | :audio_and_telemetry_only | :critical_telemetry_only`
- `audit_seq` — Monotonic sequence counter for hash-chained session audit events

### `MedCore.Profile`

Behaviour implemented by product apps (such as [`apps/med_pulse`](../../apps/med_pulse/README.md)) to compose clinical transport archetypes without touching low-level WebRTC plumbing:

- `topology/0` — Declares `:server_terminated`, `:sfu`, or `:hybrid`
- `streams/0` — Returns `[%MedCore.StreamSpec{}]`
- `inference_hooks/0` — Declares sliding-window analysis hooks gated by `integrity_state == :validated`
- `control_policy/0` — Returns the module defining parameter bounds and RBAC rules for actuated devices

---

## The 5 Pure Clinical State Machines

| Module | Responsibility | Key Emitted Effects / Facts |
| --- | --- | --- |
| `MedCore.SignalIntegrity` | Evaluates client `MediaStreamTrack.getSettings()` DSP-off attestations (`echoCancellation`, `noiseSuppression`, `autoGainControl`), RTCP `remote-inbound-rtp` loss, jitter, PCM clipping, and hardware sample-counter continuity—separately for `{:preview_stream, stream_id}` and `{:recording_artifact, acquisition_id}`. | `{:publish_ui, :integrity, report}`, `{:emit_fact, :integrity_reported, report}`, `{:tag_archive_span, :non_diagnostic, t0..t1}` |
| `MedCore.TimelineAligner` | Maintains a pure linear-regression / median-offset clock model per participant (`hardware_sample_idx` / `rtp_timestamp` ↔ `session_t_ms`) with explicit `uncertainty_ms` and exact monotonic sample-gap detection. | Annotated canonical timestamps on telemetry, capture artifacts, and inference results |
| `MedCore.ControlInterlock` | Two-phase, role-authorized command FSM enforcing clinician RBAC, exclusive control leases, parameter bounds, nonce idempotency, and deadman ACK deadlines with automatic `:safe_fallback`. | `{:rtc_send_datachannel, peer, :control, cmd}`, `{:schedule_timeout, {:cmd_ack, nonce}, ms}`, `{:append_audit_log, record}` |
| `MedCore.DegradationPolicy` | Consumes RTCP/TWCC bandwidth and loss snapshots and applies priority-ordered media adaptation so clinician talking-head video never starves diagnostic audio or ECG telemetry. | `{:rtc_set_simulcast_layer, peer, :low}`, `{:rtc_pause_track, peer, track_id}` |
| `MedCore.AuditChain` | Produces deterministic SHA-256 hash-chained audit records (`prev_hash`, `seq`, `actor`, `action`, `payload_sha256`, `session_t_ms`) for joins, reconnects, captures, AI advisory displays, and device commands. | `{:append_audit_log, %AuditRecord{}}` |

---

## Canonical Worked Event Sequence (Reconnect & Duplicate Delivery)

This worked trace is the shared contract test between `med_ex` (producer of live-session and capture facts) and external clinical workflow consumers such as `med_fabric`'s `mf_domain` (which owns clinical acceptance and observation rules):

> **Scenario**: The clinician loses the live preview. The device finishes recording. The browser rejoins the session. The capture-complete notification arrives twice. The clinician sees the preview interruption, the recording’s independently reported integrity, and one acquisition available for review.

| Step | Input Event to `MedCore.Session` | State Transition | Producer Facts / Effects Emitted |
| --- | --- | --- | --- |
| **1. Active Capture** | `acquisition_started(session_id: "s1", encounter_ref: "enc1", acquisition_id: "acq1", stream_id: "auscultation", t_ms: 10_000)` | Registers `"acq1"` as `:active` under `"s1"`. Clinician preview is active on `connection_id: "conn_a"`. | `{:append_audit_log, ...}`, `{:start_lossless_capture, "auscultation", "acq1"}` |
| **2. Clinician Preview Drops** | `peer_disconnected(session_id: "s1", peer_id: "clin_1", connection_id: "conn_a", t_ms: 14_200)` | Marks `"conn_a"` `:disconnected`. Session `"s1"` and acquisition `"acq1"` stay alive. Marks `{:preview_stream, "auscultation"}` degraded/unknown over `14_200..` while leaving `{:recording_artifact, "acq1"}` untouched. | `{:emit_fact, :peer_connection_changed, %{session_id: "s1", connection_id: "conn_a", state: :disconnected}}`, `{:emit_fact, :integrity_reported, %{subject: {:preview_stream, "auscultation"}, interval_ms: {14_200, 14_200}, continuity: :unknown, reasons: [:preview_disconnected]}}` |
| **3. Device Finishes Recording** | `capture_completed(session_id: "s1", acquisition_id: "acq1", artifact_sha256: "abc...", interval_ms: {10_000, 20_000}, missing_samples: 0, delivery_id: "deliv_1", t_ms: 20_050)` | Transitions `"acq1"` to `:completed`, stores idempotency key `("acq1", "abc...")`, and records `{:recording_artifact, "acq1"}` as `:validated` (`:observed_continuous`). | `{:emit_fact, :integrity_reported, %{subject: {:recording_artifact, "acq1"}, interval_ms: {10_000, 20_000}, continuity: :observed_continuous}}`, `{:emit_fact, :capture_completed, %{encounter_ref: "enc1", session_id: "s1", acquisition_id: "acq1", artifact_sha256: "abc...", continuity: :observed_continuous}}` |
| **4. Browser Rejoins Same Session** | `peer_connected(session_id: "s1", peer_id: "clin_1", connection_id: "conn_b", t_ms: 21_000)` | Attaches `"conn_b"` to existing `"s1"`. Closes the preview gap interval `{14_200, 21_000}` for `{:preview_stream, "auscultation"}`. | `{:emit_fact, :peer_connection_changed, %{session_id: "s1", connection_id: "conn_b", state: :connected}}`, `{:publish_ui, :session_snapshot, %{preview_interruption: {14_200, 21_000}, completed_acquisitions: ["acq1"]}}` |
| **5. Duplicate Capture-Complete Arrives** | `capture_completed(session_id: "s1", acquisition_id: "acq1", artifact_sha256: "abc...", interval_ms: {10_000, 20_000}, missing_samples: 0, delivery_id: "deliv_2", t_ms: 21_300)` | Matches existing completed `("acq1", "abc...")`. **No duplicate acquisition or duplicate fact is created** (conflicting digest for the same `acquisition_id` would instead emit a `:capture_conflict` anomaly). | `{:append_audit_log, :duplicate_capture_ignored}` (idempotent no-op for downstream consumers) |

### Resulting Invariants

- **Clinician UI** displays two distinct facts: (a) live preview was interrupted from `14.2s` to `21.0s`, and (b) recording `"acq1"` (`10.0s–20.0s`) has independently observed continuity (`:observed_continuous`, `0` missing samples).
- **Downstream Consumer (`med_fabric` / `mf_domain`)** receives one idempotent `capture_completed` fact correlated by `(encounter_ref, session_id, acquisition_id)` and owns the separate clinician decision to accept or reject the resulting observation.

---

## Planned Module Layout

```text
core/med_core/lib/
├── med_core.ex
└── med_core/
    ├── stream_spec.ex
    ├── session.ex
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

1. The canonical reconnect + duplicate `capture_completed` trace above (verifying preview vs. recording integrity separation and idempotency).
2. Diagnostic auscultation packet loss crossing `0.05%` → affected span tagged `:non_diagnostic` and advisory AI output suppressed.
3. Sustained `15 ppm` clock drift between ECG (250 Hz) and stethoscope (4 kHz) → aligned offset error bounded `< 10 ms`.
4. Concurrent control commands from two clinicians + dropped device ACK → strict mutual exclusion and `:safe_fallback` timeout.

## Related Packages

- [MedEx Workspace Overview](../../README.md)
- [MedRTC (OTP Effect Runtime)](../med_rtc/README.md)
- [MedAdapters (Clinical Signal & Media Ports)](../med_adapters/README.md)
- [MedWeb (LiveView Workbench)](../med_web/README.md)
- [MedPulse (First Reference App)](../../apps/med_pulse/README.md)
