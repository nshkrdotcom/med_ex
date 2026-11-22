<p align="center">
  <img src="assets/med_rtc.svg" width="200" height="200" alt="MedRTC logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex">
    <img alt="GitHub: med_ex" src="https://img.shields.io/badge/GitHub-med_ex-0b0f14?logo=github" />
  </a>
  <a href="LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# MedRTC

`med_rtc` is the **OTP effect shell and WebRTC/Opus/SCTP transport runtime** for the [MedEx](../../README.md) framework.

It owns process supervision, network sockets, media pipelines, timers, PubSub dispatch, and effect interpretation—while delegating every clinical state decision to the pure functional reducer in [`med_core`](../med_core/README.md).

---

## Per-Encounter OTP Supervision Architecture

Each active clinical session is isolated under a `PartitionSupervisor` + `Registry` inside its own `MedRTC.EncounterSupervisor` using a **`:rest_for_one`** restart strategy:

```text
MedRTC.EncounterRegistry (Registry)
MedRTC.EncounterPool (PartitionSupervisor -> DynamicSupervisor)
└── MedRTC.EncounterSupervisor (:rest_for_one, per encounter_id)
    ├── 1. MedRTC.AuditBuffer
    │      Flushes hash-chained clinical audit records even if media crashes.
    ├── 2. MedRTC.EncounterServer (GenServer)
    │      Holds %MedCore.Encounter{}, runs MedCore.Encounter.step/2,
    │      and delegates effects to MedRTC.EffectInterpreter.
    ├── 3. MedRTC.PeerSupervisor (DynamicSupervisor)
    │      Supervises ExWebRTC.PeerConnection + Membrane.Pipeline workers.
    │      A dropped browser or pipeline crash isolates cleanly and emits
    │      a pure :peer_disconnected event without killing edge telemetry
    │      or the audit trail.
    └── 4. MedRTC.InferenceSupervisor (Task.Supervisor, bounded concurrency)
           Dispatches Ortex / Python biosignal windows. A slow or crashing ML
           worker degrades to :inference_unavailable without stalling media.
```

---

## Effect Interpreter Routing

Effects returned by `MedCore.Encounter.step/2` are plain data structures executed by `MedRTC.EffectInterpreter`:

| Effect Family | Example Tuples | Runtime Target |
| --- | --- | --- |
| **Network / WebRTC** | `{:rtc_apply_offer, ...}`, `{:rtc_send_datachannel, ...}`, `{:rtc_set_bitrate, ...}` | Supervised `ExWebRTC.PeerConnection` & `ExSCTP` channels |
| **Media Pipelines** | `{:start_lossless_capture, stream_id, range}`, `{:tee_to_inference, stream_id, adapter}` | Dynamic pad linking in `Membrane.Pipeline` (zero-copy BEAM binary refs) |
| **Compute / OSS** | `{:run_inference, adapter, window}`, `{:analyze_biosignal, adapter, batch}` | Bounded `InferenceSupervisor` → `med_adapters` NIFs or Ports |
| **UI Deltas** | `{:publish_ui, topic, delta}` | `Phoenix.PubSub` (coalesced for 30–60 Hz waveform rendering) |
| **Durability & Timers** | `{:append_audit_log, record}`, `{:schedule_timeout, ref, ms}`, `{:export_fhir, bundle}` | `AuditBuffer`, OTP process timers, async durable writers |

---

## Target Open-Source Transport Stack (Phase 1B)

- **ExWebRTC** (<https://github.com/elixir-webrtc/ex_webrtc>): Native Elixir W3C WebRTC implementation supporting DTLS-SRTP, ICE, RTP/RTCP, `remote-inbound-rtp` packet-loss telemetry, and custom per-encounter DTLS `key_cert` injection.
- **ExSCTP** (<https://github.com/elixir-webrtc/ex_sctp>): Rust-backed (`sctp_proto`) DataChannel transport for lossless ECG/SpO₂ telemetry, 4 kHz diagnostic PCM audio, and audited device control channels.
- **Membrane Core & Plugins** (<https://github.com/membraneframework/membrane_core>):
  - `membrane_webrtc_plugin` (<https://github.com/membraneframework/membrane_webrtc_plugin>)
  - `membrane_opus_plugin` (<https://github.com/membraneframework/membrane_opus_plugin>)
  - `membrane_wav_plugin` (<https://github.com/membraneframework/membrane_wav_plugin>) — lossless PCM/WAV ring-buffer archival
  - `membrane_rtc_engine` (<https://github.com/fishjam-dev/membrane_rtc_engine>) — in-BEAM SFU for multi-clinician Archetype C sessions (2–8 peers)
- **Rel** (<https://github.com/elixir-webrtc/rel>): Standalone Elixir TURN/STUN server for hospital NAT traversal when direct UDP P2P fails.
- **ExWebRTC Recorder** (<https://github.com/elixir-webrtc/ex_webrtc_recorder>): Raw RTP packet capture for deterministic incident replay.

---

## Security & PHI Isolation Guarantees

1. **Per-Encounter DTLS Certificates**: Inject ephemeral `key_cert` pairs into `ExWebRTC.PeerConnection` bound to `(encounter_id, peer_id)`.
2. **Transient Media by Default**: RTP and SCTP waveform buffers remain in volatile RAM unless an audited clinician control command triggers clip archival.
3. **Never P2P Control**: Control DataChannels always terminate in the BEAM `EncounterServer` so RBAC, nonce idempotency, and audit hashing cannot be bypassed.

---

## Planned Module Layout

```text
core/med_rtc/lib/
├── med_rtc.ex
└── med_rtc/
    ├── encounter_supervisor.ex
    ├── encounter_server.ex
    ├── effect_interpreter.ex
    ├── audit_buffer.ex
    ├── peer_supervisor.ex
    ├── media_pipeline.ex
    ├── signal_router.ex
    └── turn_config.ex
```

## Related Packages

- [MedEx Workspace Overview](../../README.md)
- [MedCore (Pure Functional Core)](../med_core/README.md)
- [MedAdapters (Clinical OSS Ports)](../med_adapters/README.md)
- [MedWeb (LiveView Workbench)](../med_web/README.md)
- [MedPulse (First Reference App)](../../apps/med_pulse/README.md)
