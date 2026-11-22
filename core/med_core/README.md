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

`med_core` is the pure functional core of [MedEx](../../README.md). It has zero `GenServer`s, zero network calls, zero filesystem I/O, and zero wall-clock reads: every live-session transition is a deterministic `{next_session, effects}` step from `MedCore.Session.step/2`.

---

## What This Owns (and Does Not Own)

**`med_core` owns:**
- `MedCore.Session` — Pure session struct and `step/2` reducer tracking four independent IDs (`encounter_ref`, `session_id`, `connection_id`, `acquisition_id`), active/closed `preview_interruptions`, and the single authoritative `integrity_reports` map keyed by `{:preview_stream, stream_id}` or `{:recording_artifact, acquisition_id}`.
- `MedCore.StreamSpec` — Declarative stream contract (`archetype`, `modality`, `codec_profile`, `priority`, `integrity_policy`).
- `MedCore.Profile` — Minimal behaviour (`topology/0`, `streams/0`) implemented by host applications.

**`med_core` does not own:**
- OTP processes, WebRTC sockets, or WAV I/O (those belong in [`core/med_rtc`](../med_rtc/README.md)).
- Durable clinical encounters, clinician acceptance, or FHIR exports (those belong in `med_fabric`'s `mf_domain`, `mf_store`, and `mf_interop`).

---

## Core Invariants Verified Today

1. **Four-level identity**: `encounter_ref` is optional (`nil` in standalone mode). `session_id` outlasts individual `connection_id` drops. `acquisition_id` completes independently of live viewer connections.
2. **Preview vs. recording integrity**: A disconnect on `conn_a` records `{:preview_stream, stream_id}` continuity `:unknown` and opens a preview interruption interval without altering `{:recording_artifact, acquisition_id}`.
3. **Three continuity states**: `:observed_continuous`, `:observed_gap`, and `:unknown` (never silently treating unmonitored intervals as continuous).
4. **Late-disconnect safety**: Once `conn_b` replaces `conn_a` for the same `peer_id`, a delayed `:peer_disconnected` for `conn_a` is ignored and does not open a false preview outage.
5. **Idempotent & conflict-safe capture completion**: Duplicate `capture_completed` events with the same `(acquisition_id, artifact_sha256)` are ignored cleanly; a conflicting `artifact_sha256` marks the acquisition `:conflict` (sticky) and emits `{:emit_fact, :capture_conflict, ...}`.

---

## Walkthrough

```elixir
session = MedCore.Session.new(id: "s1", encounter_ref: "enc1", streams: [stream])
{session, _e1} = MedCore.Session.step(session, {:peer_connected, %{peer_id: "clin_1", connection_id: "conn_a", role: :clinician, t_ms: 100}})
{session, _e2} = MedCore.Session.step(session, {:acquisition_started, %{acquisition_id: "acq_1", stream_id: "auscultation", t_ms: 200}})
{session, _e3} = MedCore.Session.step(session, {:peer_disconnected, %{peer_id: "clin_1", connection_id: "conn_a", t_ms: 400}})
{session, e4}  = MedCore.Session.step(session, {:capture_completed, %{acquisition_id: "acq_1", artifact_sha256: "sha1", interval_ms: {200, 1200}, continuity: :observed_continuous, delivery_id: "d1", t_ms: 1250}})
```

See `test/med_core_test.exs` for all 4 executable tests covering reconnects, `:unknown` continuity, late disconnects, duplicate deliveries, and sticky digest conflicts.

---

## Commands & Verification

```bash
cd core/med_core
mix test
mix credo --strict
mix dialyzer --force-check
```

## Planned Extensions (Deferred Until Needed)

Dedicated sub-reducers for multi-stream clock alignment (`TimelineAligner`), actuated device command interlocks (`ControlInterlock`), and hash-chained audit logs (`AuditChain`) will be added only when a concrete hardware/UI workflow exercises them.

## Related Packages

- [MedEx Workspace](../../README.md)
- [MedRTC](../med_rtc/README.md)
- [MedWeb](../med_web/README.md)
- [MedAdapters](../med_adapters/README.md)
- [MedPulse](../../apps/med_pulse/README.md)
