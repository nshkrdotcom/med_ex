<p align="center">
  <img src="assets/med_ex.svg" width="200" height="200" alt="MedEx logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex">
    <img alt="GitHub: med_ex" src="https://img.shields.io/badge/GitHub-med_ex-0b0f14?logo=github" />
  </a>
  <a href="https://github.com/nshkrdotcom/med_ex/blob/main/LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# MedEx

`MedEx` is a reusable Elixir/Phoenix/LiveView/WebRTC/Opus poncho framework and reference application suite for connected medical devices.

Instead of building a leaky "generic video call" wrapper, `MedEx` inverts the typical WebRTC architecture: **clinical signal integrity, multi-stream time alignment, and audited device control are the core domain**, while WebRTC, Opus, RTP, and SCTP are pluggable transports that serve those invariants.

This repository is a non-umbrella Elixir poncho workspace orchestrated with [Blitz](https://github.com/nshkrdotcom/blitz) and [Weld](https://github.com/nshkrdotcom/weld). The root `mix.exs` (`:med_ex_workspace`) is a tooling-only project that coordinates builds, formatting, Credo, Dialyzer, ExDoc, tests, and welded package projection across all child Mix packages.

---

## Poncho Architecture & Package Map

Every reusable core package lives under `core/`, and product/vertical-slice applications built on top of the framework live under `apps/`.

```text
med_ex/
├── mix.exs                         # Tooling root (:med_ex_workspace) with Blitz + Weld
├── build_support/weld.exs          # Weld publication manifest for the unified core artifact
├── core/
│   ├── med_core/                   # Pure functional core (zero OTP, zero IO, 100% deterministic)
│   ├── med_rtc/                    # OTP effect runtime, supervision tree, ExWebRTC/ExSCTP/Membrane shell
│   ├── med_adapters/               # Behaviour-driven clinical OSS adapters (Ortex, NeuroKit2/WFDB, FHIR, Orthanc)
│   └── med_web/                    # Reusable Phoenix Signaling, LiveComponents, JS WebAudio/WebRTC hooks
└── apps/
    └── med_pulse/                  # First vertical slice: Use Cases #1 (Digital Stethoscope) + #4 (RPM ECG/SpO2)
```

### Sub-Package Documentation

| Package | Path | Layer | Role | Documentation |
| --- | --- | --- | --- | --- |
| **MedCore** | `core/med_core` | Pure Functional Core | Clinical contracts (`StreamSpec`, `Encounter`, `Profile`), pure `step/2` reducer, and 5 deterministic state machines (`SignalIntegrity`, `TimelineAligner`, `ControlInterlock`, `DegradationPolicy`, `AuditChain`) | [core/med_core/README.md](core/med_core/README.md) |
| **MedRTC** | `core/med_rtc` | OTP Runtime & Transport Shell | Per-encounter `:rest_for_one` supervision, `EffectInterpreter`, `ExWebRTC`/`ExSCTP`/`Membrane` pipelines, `Rel` TURN/STUN config, and security/DTLS key pinning | [core/med_rtc/README.md](core/med_rtc/README.md) |
| **MedAdapters** | `core/med_adapters` | External OSS & Clinical Ports | `@behaviour` contracts and isolated adapters for in-BEAM ONNX (`Ortex`/`Nx`), Python biosignal workers (`NeuroKit2`, `wfdb-python`), `HAPI FHIR`/`Medplum`, `Orthanc` DICOMweb, `LiveKit`, and `Pipecat`/`whisper.cpp` | [core/med_adapters/README.md](core/med_adapters/README.md) |
| **MedWeb** | `core/med_web` | Phoenix & LiveView Workbench | Signed encounter tokens, WebRTC signaling channel, reusable LiveComponents, WebAudio `AudioWorklet` PCM hooks, and `ex_webrtc_dashboard` metrics | [core/med_web/README.md](core/med_web/README.md) |
| **MedPulse** | `apps/med_pulse` | Reference Product App | First vertical slice implementing Use Cases **#1 (Remote Digital Stethoscope)** + **#4 (Remote Patient Monitoring: ECG/SpO₂)** with 4 kHz PCM-over-SCTP, `open-stethoscope` ONNX, `NeuroKit2`/`WFDB`, `pion/webrtc` edge gateway, and FHIR export | [apps/med_pulse/README.md](apps/med_pulse/README.md) |

---

## 4 Orthogonal Clinical Transport Archetypes (Generalizing All 12 Use Cases)

Forcing all 12 connected-medical-device use cases through a single "WebRTC Room" abstraction breaks clinical safety: browser AEC/NS/AGC ruins digital stethoscope heart sounds; ECG waveforms must never pass through a lossy audio codec; conversational medical voice AI needs full-duplex VAD barge-in rather than multi-peer video fan-out.

`MedEx` decomposes all 12 use cases into **4 composable Clinical Transport Archetypes**. A concrete clinical product simply composes archetypes inside one synchronized `MedCore.Encounter` via `MedCore.Profile`:

| Archetype | Core Signal & Protocol Contract | Optimal WebRTC Topology | Degradation & Safety Rule | Covered Use Cases |
| --- | --- | --- | --- | --- |
| **A. Diagnostic Signal Plane** *(High-Fidelity Biosignal Audio)* | Unprocessed PCM over ordered/partially-reliable SCTP DataChannel **or** high-bitrate validated Opus (`stereo=0; maxaveragebitrate=128000; cbr=1; useinbandfec=1`) with browser `echoCancellation: false`, `noiseSuppression: false`, `autoGainControl: false`. | **Server-Terminated Pipeline** (`ex_webrtc` → `membrane_core`) so the server tees the exact bit-stream to lossless WAV archive, real-time ONNX QC/screening, and clinician playback. | If packet loss exceeds policy, clipping occurs, or client fails DSP-off attestation, **flag frame span as `:non_diagnostic`** in real time (never silently conceal with PLC). | **#1** Digital Stethoscope, **#8** Respiratory/Spirometer Sounds, **#9** Speech Therapy (acoustic assessment), **#11** Hearing Aid Fitting (calibrated audio) |
| **B. Structured Telemetry & Control Plane** *(Lossless Sensor & Interlock)* | Binary framed waveforms (ECG, SpO₂, PPG, airflow, device diagnostics) on SCTP DataChannels (`ex_sctp`) + **separate** authenticated, nonce-sequenced, ACKed Control DataChannel. | **Star / Hub-and-Spoke** terminated in BEAM (`ex_webrtc` + `ex_sctp`). Control commands are never P2P; the BEAM encounter is the sole authorization & audit authority. | Telemetry carries monotonic hardware sample counters (exact gap detection); Control channel enforces **deadman timeout + idempotency + state-machine interlocks** before actuating settings. | **#4** RPM (ECG/SpO₂), **#10** Remote Device Troubleshooting, **#11** Hearing Device Parameter Fitting, **#3** & **#7** (vitals channels) |
| **C. Interactive Clinical Media Plane** *(Human-to-Human A/V + Annotations)* | Adaptive Opus (24–48 kbps, DTX, FEC, AEC/NS/AGC **on**) + H.264/VP8 video (simulcast/SVC) + lightweight JSON/CBOR annotation DataChannel (telestration vectors, freeze-frame markers). | **SFU** (`membrane_rtc_engine` in-BEAM for 2–8 clinicians; optional `livekit` adapter for large cohorts). Never full mesh beyond 2–3 peers due to mobile/EMS uplink limits. | Graceful degradation ladder: drop video resolution → drop video FPS → freeze video / preserve Opus audio + telemetry. Never starve Archetype A/B bandwidth for talking-head video. | **#3** Connected Telehealth, **#6** Remote Ultrasound, **#7** Tele-EMS, **#9** Speech Therapy (articulation video), **#12** Remote Clinical Training |
| **D. Full-Duplex Conversational AI Plane** *(Streaming Speech-to-Agent)* | Low-latency Opus (16–24 kHz, 20 ms frames) terminated on server → VAD (`silero-vad` via `Ortex`) → streaming ASR (`Bumblebee`/`whisper.cpp`) → deterministic clinical guardrails + LLM → TTS back over Opus RTP. | **Edge-to-Server-Terminated** (`ex_webrtc` + `membrane_opus_plugin`, or bridged to `pipecat` over WebRTC/gRPC). | Barge-in cancellation on VAD speech-start; **hard deterministic escalation router** (red-flag symptoms or confidence drop triggers immediate warm handoff to Archetype C clinician SFU). | **#2** AI Voice Patient Monitoring, **#5** AI Medical Voice Assistants |

### Composition Map Across All 12 Use Cases

- **#1 Remote Digital Stethoscope** = `A (Auscultation)` + `C (Audio-only talkback)` + `B (Filter/Capture control)`
- **#2 AI Voice Patient Monitoring** = `D (Conversational/Breath capture)` + `A (Cough/Voice biomarker tee)`
- **#3 Connected Telehealth Medical Devices** = `C (Video visit)` + `A (Stethoscope)` + `B (Vitals + Device control)`
- **#4 Remote Patient Monitoring (RPM)** = `B (ECG/SpO₂ telemetry)` + `C (On-demand Opus voice)`
- **#5 AI Medical Voice Assistants** = `D (Full-duplex voice agent)` + `C (Clinician escalation handoff)`
- **#6 Remote Ultrasound & Imaging** = `C (High-bitrate H.264 + telestration)` + `DICOM/Orthanc Archive Sink`
- **#7 Emergency Medicine / Tele-EMS** = `C (Adaptive video + Opus)` + `B (Live monitor vitals)` + `Cellular-resilient degradation policy`
- **#8 Respiratory Health Devices** = `A (Validated breath/spirometry acoustic)` + `B (Flow/volume telemetry)`
- **#9 Speech Therapy & Rehabilitation** = `A (High-fidelity voice assessment)` + `C (Lip/articulation video)`
- **#10 Remote Device Troubleshooting** = `B (Device logs + authenticated remote config)` + `C (Opus/video guidance)`
- **#11 Connected Hearing & Assistive Devices** = `B (Audiogram/DSP parameter control)` + `A/C (Calibrated audio + voice)`
- **#12 Remote Clinical Training & Guidance** = `C (1-to-N SFU video + synchronized vector annotations)`

---

## System Topology

```text
+---------------------------+        +-----------------------------------------+
|  EDGE / PATIENT SIDE      |        |  CLINICIAN BROWSER (Phoenix LiveView)   |
|                           |        |                                         |
| [1] Hardware Edge Gateway |        |  - LiveExWebRTC / Membrane JS Hooks     |
|     (Go + pion/webrtc)    |        |  - WebAudio Worklet (Diagnostic Audio)  |
|     BLE/USB Steth + ECG   |        |  - Canvas/WebGL Synced Waveform View    |
|            OR             |        |  - Control Interlock & Integrity Badges |
| [2] Patient Browser / App |        +--------------------+--------------------+
|     WebAudio(DSP-off) +   |                             |
|     WebBLE / Sim Replay   |                             | WSS (Signaling + LiveView)
+-------------+-------------+                             | + SRTP/DTLS/SCTP (WebRTC)
              | SRTP (Opus) + SCTP (PCM/ECG/Control)      |
              | (via `rel` TURN/STUN if behind hospital NAT)
              v                                           v
+==============================================================================+
|                  ELIXIR / OTP BACKEND (MedEx Poncho Workspace)               |
|                                                                              |
|  [core/med_web: Phoenix + LiveView + Signaling Channels + LiveDashboard]     |
|         |                                             ^                      |
|         v (normalized %Event{})                       | (PubSub UI deltas)   |
|  +------------------------------------------------------------------------+  |
|  | core/med_rtc: EncounterSupervisor (:rest_for_one per Encounter ID)     |  |
|  |                                                                        |  |
|  |  +-----------------------------+     +------------------------------+  |  |
|  |  | EncounterServer (GenServer) |     | MediaPipeline (Membrane)     |  |  |
|  |  |  - Holds %MedCore.Encounter |---->|  - ex_webrtc / webrtc_plugin |  |  |
|  |  |  - Calls MedCore.step/2     |<----|  - membrane_opus_plugin      |  |  |
|  |  |  - Runs EffectInterpreter   |     |  - membrane_wav_plugin (tee) |  |  |
|  |  +--------------+--------------+     |  - ex_sctp DataChannel Demux |  |  |
|  |                 |                    +-------+--------------+-------+  |  |
|  |                 v                            v              |          |  |
|  |  +-----------------------------+     +---------------+      |          |  |
|  |  | AuditBuffer & ControlTimer  |     | SignalRouter  |      |          |  |
|  |  +-----------------------------+     +-------+-------+      |          |  |
|  +----------------------------------------------|--------------|----------+  |
|                                                 |              |             |
|  [core/med_adapters: Behaviour-Driven Ports & NIFs]            |             |
|    +--------------------------+   +-------------------------+  |             |
|    | In-BEAM ONNX (Ortex NIF) |   | Python Biosignal Worker |  |             |
|    | - open-stethoscope ONNX  |   | (Supervised Port / gRPC)|  |             |
|    | - silero-vad ONNX        |   | - NeuroKit2 (ECG/HRV)   |  |             |
|    +--------------------------+   | - wfdb-python (Export)  |  |             |
|                                   +-------------------------+  |             |
|    +--------------------------+   +-------------------------+  |             |
|    | Clinical Archive Adapter |   | Optional External Media |<-+             |
|    | - HAPI FHIR / Medplum    |   | - LiveKit SFU (1-to-N)  |                |
|    | - Orthanc DICOMweb       |   | - Pipecat / whisper.cpp |                |
|    +--------------------------+   +-------------------------+                |
+==============================================================================+
```

---

## Vetted Open-Source GitHub Ecosystem

Every external library has a distinct architectural role across the poncho layers:

### A. Elixir WebRTC, Media Pipelines & LiveView Transport (`core/med_rtc`, `core/med_web`)

- **ExWebRTC** — <https://github.com/elixir-webrtc/ex_webrtc> (Native Elixir W3C WebRTC API: DTLS-SRTP, ICE, RTP/RTCP, inbound packet-loss stats, custom key/cert injection)
- **ExSCTP** — <https://github.com/elixir-webrtc/ex_sctp> (Rust-backed `sctp_proto` DataChannel support for lossless telemetry and control planes)
- **LiveExWebRTC** — <https://github.com/elixir-webrtc/live_ex_webrtc> (Phoenix LiveComponents for WebRTC signaling and playback)
- **ExWebRTC Recorder & Dashboard** — <https://github.com/elixir-webrtc/ex_webrtc_recorder> and <https://github.com/elixir-webrtc/ex_webrtc_dashboard> (RTP recording and LiveDashboard metrics)
- **Rel (Elixir TURN/STUN)** — <https://github.com/elixir-webrtc/rel> (Standalone TURN/STUN relay for hospital NATs/firewalls)
- **Membrane Core & Plugins** — <https://github.com/membraneframework/membrane_core>, <https://github.com/membraneframework/membrane_webrtc_plugin>, <https://github.com/membraneframework/membrane_opus_plugin>, <https://github.com/membraneframework/membrane_wav_plugin>, and <https://github.com/fishjam-dev/membrane_rtc_engine>

### B. In-BEAM Numerical Computing & Local AI Inference (`core/med_adapters`)

- **Nx & Ortex (ONNX Runtime NIF)** — <https://github.com/elixir-nx/nx> and <https://github.com/elixir-nx/ortex> (Sub-10ms in-BEAM tensor preprocessing and ONNX inference)
- **Bumblebee** — <https://github.com/elixir-nx/bumblebee> (Local Whisper ASR and neural models on Axon/EXLA)
- **Silero VAD** — <https://github.com/snakers4/silero-vad> (~2 MB MIT ONNX VAD runnable directly via `Ortex`)

### C. Medical Signal Processing, Clinical Archives, Edge & Voice-AI (`core/med_adapters`, `apps/med_pulse`)

- **Open-Stethoscope** — <https://github.com/NoahIsARider/open-stethoscope> (PhysioNet-2022 CirCor heart murmur & auscultation position-QC, 1.6 MB ONNX)
- **NeuroKit2** — <https://github.com/neuropsychology/NeuroKit> (ECG, RSP, PPG/SpO₂, R-peak detection, HRV, and signal quality indices)
- **WFDB-Python (MIT PhysioNet)** — <https://github.com/MIT-LCP/wfdb-python> (Standardized clinical waveform database export/replay)
- **HAPI FHIR & Medplum** — <https://github.com/hapifhir/hapi-fhir> and <https://github.com/medplum/medplum> (HL7 FHIR R4/R5 `Encounter`, `Observation`, `Device`, `DiagnosticReport`)
- **Orthanc** — <https://github.com/jodogne/OrthancMirror> and <https://github.com/orthanc-server/orthanc-setup-samples> (DICOM/DICOMweb PACS archive for ultrasound/imaging)
- **Pion WebRTC (Go)** — <https://github.com/pion/webrtc> (Static edge gateway binary for ARM/Linux medical carts and PhysioNet fixture replay)
- **Pipecat & whisper.cpp** — <https://github.com/pipecat-ai/pipecat> and <https://github.com/ggml-org/whisper.cpp> (Full-duplex conversational voice-AI pipelines)
- **LiveKit** — <https://github.com/livekit/livekit> (Optional external Go SFU adapter for 1-to-N clinical training cohorts)

---

## Phased Delivery Plan

1. **Phase 0 (Current — Architecture & Skeleton Poncho)**: Establish the `core/*` + `apps/*` poncho workspace, Blitz parallel runner, Weld graph & monolith verification, Credo/Dialyzer/ExDoc baselines, custom SVG assets, and full architecture specifications in every package README.
2. **Phase 1A — Pure Core & Deterministic Trace Suite ([`core/med_core`](core/med_core/README.md))**: Implement `StreamSpec`, `Encounter`, `SignalIntegrity`, `TimelineAligner`, `ControlInterlock`, `DegradationPolicy`, and `AuditChain` with property-based verification of packet loss, 15 ppm clock drift, and concurrent control interlock races.
3. **Phase 1B — OTP Runtime & Edge Harness ([`core/med_rtc`](core/med_rtc/README.md))**: Wire `ExWebRTC`, `ExSCTP`, `Membrane`, and `Rel` under `EncounterSupervisor` plus the `pion/webrtc` PhysioNet fixture publisher.
4. **Phase 1C — Clinical OSS Adapters ([`core/med_adapters`](core/med_adapters/README.md))**: Load `open-stethoscope` ONNX into `Ortex`/`Nx`, supervise `NeuroKit2` + `wfdb-python` behind length-prefixed binary Erlang `Port`s, and wire `HAPI FHIR` export.
5. **Phase 1D — LiveView Clinical Workbench & First Vertical Slice ([`core/med_web`](core/med_web/README.md), [`apps/med_pulse`](apps/med_pulse/README.md))**: Deliver `<.med_session />`, `<.signal_integrity_badge />`, `<.sync_waveform_canvas />`, `<.control_interlock_bar />`, WebAudio `AudioWorklet` Bell/Diaphragm filtering, and `ex_webrtc_dashboard` telemetry for `MedPulse` (#1 + #4).

---

## Workspace Commands (Blitz & Weld)

Run all tooling from the repository root:

```bash
# Install root tooling deps and all child poncho project deps
mix deps.get
mix monorepo.deps.get

# Run tests, formatting, compile, Credo, and Dialyzer across all core/* and apps/* repos via Blitz
mix monorepo.compile
mix monorepo.test
mix monorepo.credo -- --strict
mix monorepo.dialyzer
mix ci

# Inspect the poncho dependency graph and verify the welded core artifact via Weld
mix weld.inspect
mix weld.graph
mix weld.verify
```

## Security & Regulatory Boundary

WebRTC DTLS-SRTP provides transport encryption in transit, which is necessary but insufficient for HIPAA/FDA compliance. `MedEx` enforces:

- **Identity & Key Pinning**: Short-lived per-encounter DTLS certificates and role-scoped signed signaling tokens.
- **PHI Isolation**: Media/RTP frames stay transient in RAM unless captured via an audited clinician control command; persisted artifacts require envelope encryption at rest.
- **SaMD Advisory Guardrail**: Every inference output carries `advisory_only: true`, `model_sha256`, `signal_quality_score`, and the input window's exact `integrity_state` so degraded segments never surface misleading AI scores.

## License

MIT — see [LICENSE](LICENSE).
