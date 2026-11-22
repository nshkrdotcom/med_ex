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

`MedEx` is a reusable Elixir/Phoenix/LiveView/WebRTC/Opus SDK poncho for connected medical devices.

Instead of building a leaky "generic video call" wrapper, `MedEx` inverts the typical WebRTC architecture: **clinical signal integrity, multi-stream time alignment, lossless capture continuity, and audited device control are the core domain**, while WebRTC, Opus, RTP, and SCTP are pluggable transports that serve those invariants.

This repository is a non-umbrella Elixir poncho workspace orchestrated with [Blitz](https://github.com/nshkrdotcom/blitz) and [Weld](https://github.com/nshkrdotcom/weld). The root `mix.exs` (`:med_ex_workspace`) is a tooling-only project that coordinates parallel child checks and projects the consumable `:med_ex` SDK artifact.

---

## Ownership Boundary (`med_ex` SDK vs. `med_fabric` Product Platform)

`MedEx` owns the **reusable real-time clinical signal, live session, WebRTC/Opus/Membrane transport, browser media workbench, and opt-in live signal-compute plane**.

Durable clinical encounters, clinician observation acceptance, transactional outbox persistence, HL7 FHIR delivery, and full clinical product applications live in the companion `med_fabric` workspace (`mf_domain`, `mf_runtime`, `mf_store`, `mf_interop`, `apps/exam`). Dependencies flow strictly one-way (`med_fabric` → `:med_ex`), while `med_ex` remains usable standalone without requiring an external `encounter_ref`.

- **Single SDK Distribution Identity (`:med_ex`)**: Downstream consumers such as `med_fabric/apps/exam` depend on **one OTP app (`:med_ex`)** projected by Weld from `core/med_core`, `core/med_rtc`, and `core/med_web` (an explicitly browser-capable default SDK). `core/med_adapters` stays an opt-in source project excluded from the default projection until a concrete consumer proves compatibility against `:med_ex`'s public API; a separate headless-only SDK distribution waits for an actual headless consumer.
- **Minimal Reference App (`apps/med_pulse`)**: Proves standalone consumption of `med_ex`'s public API (two-browser WebRTC call + deterministic simulated capture + preview disconnect/rejoin + duplicate completion handling). Full clinical product roadmaps belong in `med_fabric`.
- **`MedCore.Session`** (`session_id`) outlasts individual WebRTC peer connections (`connection_id`), tracks standalone or encounter-linked captures (`acquisition_id`), and separates **live preview integrity** (`{:preview_stream, id}`) from **recording artifact integrity** (`{:recording_artifact, acquisition_id}`). See the canonical reconnect trace in [core/med_core/README.md](core/med_core/README.md).

---

## Poncho Architecture & Package Map

```text
med_ex/
├── mix.exs                         # Tooling root (:med_ex_workspace) with Blitz + Weld
├── build_support/weld.exs          # Weld manifest projecting the browser-capable :med_ex SDK
├── core/
│   ├── med_core/                   # Pure functional core (zero OTP, zero IO, 100% deterministic)
│   ├── med_rtc/                    # OTP effect runtime, supervision tree, ExWebRTC/ExSCTP/Membrane shell
│   ├── med_web/                    # Reusable Phoenix Signaling, LiveComponents, JS WebAudio/WebRTC hooks
│   └── med_adapters/               # Opt-in source project: signal/AI & external media ports (Ortex, NeuroKit2/WFDB, LiveKit, Pipecat)
└── apps/
    └── med_pulse/                  # Minimal standalone SDK reference app
```

### Sub-Package Documentation

| Package | Path | Layer | Role | Documentation |
| --- | --- | --- | --- | --- |
| **MedCore** | `core/med_core` | Pure Functional Core *(in `:med_ex` SDK)* | Clinical contracts (`StreamSpec`, `Session`, `Profile`), preview vs. recording integrity model, canonical reconnect trace, and 5 deterministic state machines (`SignalIntegrity`, `TimelineAligner`, `ControlInterlock`, `DegradationPolicy`, `AuditChain`) | [core/med_core/README.md](core/med_core/README.md) |
| **MedRTC** | `core/med_rtc` | OTP Runtime & Transport Shell *(in `:med_ex` SDK)* | Per-session `:rest_for_one` supervision, `EffectInterpreter`, `ExWebRTC`/`ExSCTP`/`Membrane` pipelines, lossless capture tees, `Rel` TURN/STUN config, and DTLS key pinning | [core/med_rtc/README.md](core/med_rtc/README.md) |
| **MedWeb** | `core/med_web` | Phoenix & LiveView Workbench *(in `:med_ex` SDK)* | Signed session tokens, WebRTC signaling channel, reusable LiveComponents, WebAudio `AudioWorklet` hooks, and `ex_webrtc_dashboard` metrics | [core/med_web/README.md](core/med_web/README.md) |
| **MedAdapters** | `core/med_adapters` | Opt-in Signal & Media Ports *(excluded from default SDK)* | `@behaviour` contracts and isolated adapters for in-BEAM ONNX (`Ortex`/`Nx`), Python biosignal workers (`NeuroKit2`, `wfdb-python`), `LiveKit`, and `Pipecat`/`whisper.cpp` | [core/med_adapters/README.md](core/med_adapters/README.md) |
| **MedPulse** | `apps/med_pulse` | Minimal SDK Reference App | Standalone proof exercising live WebRTC talkback, deterministic simulated capture, preview disconnect/rejoin, and independent recording integrity through `med_ex`'s public API | [apps/med_pulse/README.md](apps/med_pulse/README.md) |

---

## 4 Orthogonal Clinical Transport Archetypes (Generalizing All 12 Use Cases)

Forcing all 12 connected-medical-device use cases through a single "WebRTC Room" abstraction breaks clinical safety: browser AEC/NS/AGC ruins digital stethoscope heart sounds; ECG waveforms must never pass through a lossy audio codec; conversational medical voice AI needs full-duplex VAD barge-in rather than multi-peer video fan-out.

`MedEx` decomposes all 12 use cases into **4 composable Clinical Transport Archetypes**. A product composes archetypes inside one synchronized `MedCore.Session` via `MedCore.Profile`:

| Archetype | Core Signal & Protocol Contract | Optimal WebRTC Topology | Degradation & Safety Rule | Covered Use Cases |
| --- | --- | --- | --- | --- |
| **A. Diagnostic Signal Plane** *(High-Fidelity Biosignal Audio)* | Unprocessed PCM over ordered/partially-reliable SCTP DataChannel **or** high-bitrate validated Opus (`stereo=0; maxaveragebitrate=128000; cbr=1; useinbandfec=1`) with browser `echoCancellation: false`, `noiseSuppression: false`, `autoGainControl: false`. | **Server-Terminated Pipeline** (`ex_webrtc` → `membrane_core`) so the server tees the exact bit-stream to lossless capture, optional ONNX QC/screening, and clinician playback. | If packet loss exceeds policy, clipping occurs, or client fails DSP-off attestation, **flag the affected interval as `:non_diagnostic`** in real time (never silently conceal with PLC; report preview vs. recording integrity separately). | **#1** Digital Stethoscope, **#8** Respiratory/Spirometer Sounds, **#9** Speech Therapy (acoustic assessment), **#11** Hearing Aid Fitting (calibrated audio) |
| **B. Structured Telemetry & Control Plane** *(Lossless Sensor & Interlock)* | Binary framed waveforms (ECG, SpO₂, PPG, airflow, device diagnostics) on SCTP DataChannels (`ex_sctp`) + **separate** authenticated, nonce-sequenced, ACKed Control DataChannel. | **Star / Hub-and-Spoke** terminated in BEAM (`ex_webrtc` + `ex_sctp`). Control commands are never P2P; the BEAM session is the sole authorization & audit authority. | Telemetry carries monotonic hardware sample counters (exact gap detection); Control channel enforces **deadman timeout + idempotency + state-machine interlocks** before actuating settings. | **#4** RPM (ECG/SpO₂), **#10** Remote Device Troubleshooting, **#11** Hearing Device Parameter Fitting, **#3** & **#7** (vitals channels) |
| **C. Interactive Clinical Media Plane** *(Human-to-Human A/V + Annotations)* | Adaptive Opus (24–48 kbps, DTX, FEC, AEC/NS/AGC **on**) + H.264/VP8 video (simulcast/SVC) + lightweight JSON/CBOR annotation DataChannel (telestration vectors, freeze-frame markers). | **SFU** (`membrane_rtc_engine` in-BEAM for 2–8 clinicians; optional `livekit` adapter for large cohorts). Never full mesh beyond 2–3 peers due to mobile/EMS uplink limits. | Graceful degradation ladder: drop video resolution → drop video FPS → freeze video / preserve Opus audio + telemetry. Never starve Archetype A/B bandwidth for talking-head video. | **#3** Connected Telehealth, **#6** Remote Ultrasound, **#7** Tele-EMS, **#9** Speech Therapy (articulation video), **#12** Remote Clinical Training |
| **D. Full-Duplex Conversational AI Plane** *(Streaming Speech-to-Agent)* | Low-latency Opus (16–24 kHz, 20 ms frames) terminated on server → VAD (`silero-vad` via `Ortex`) → streaming ASR (`Bumblebee`/`whisper.cpp`) → deterministic clinical guardrails + LLM → TTS back over Opus RTP. | **Edge-to-Server-Terminated** (`ex_webrtc` + `membrane_opus_plugin`, or bridged to `pipecat` over WebRTC/gRPC). | Barge-in cancellation on VAD speech-start; **hard deterministic escalation router** (red-flag symptoms or confidence drop triggers immediate warm handoff to Archetype C clinician SFU). | **#2** AI Voice Patient Monitoring, **#5** AI Medical Voice Assistants |

---

## Vetted Open-Source GitHub Ecosystem

- **WebRTC, Media Pipelines & LiveView (`core/med_rtc`, `core/med_web`)**:
  - [ExWebRTC](https://github.com/elixir-webrtc/ex_webrtc), [ExSCTP](https://github.com/elixir-webrtc/ex_sctp), [LiveExWebRTC](https://github.com/elixir-webrtc/live_ex_webrtc), [ExWebRTC Recorder](https://github.com/elixir-webrtc/ex_webrtc_recorder), [ExWebRTC Dashboard](https://github.com/elixir-webrtc/ex_webrtc_dashboard), [Rel (TURN/STUN)](https://github.com/elixir-webrtc/rel)
  - [Membrane Core](https://github.com/membraneframework/membrane_core), [membrane_webrtc_plugin](https://github.com/membraneframework/membrane_webrtc_plugin), [membrane_opus_plugin](https://github.com/membraneframework/membrane_opus_plugin), [membrane_wav_plugin](https://github.com/membraneframework/membrane_wav_plugin), [membrane_rtc_engine](https://github.com/fishjam-dev/membrane_rtc_engine)
- **Opt-In Signal Compute & External Media (`core/med_adapters`)**:
  - [Nx](https://github.com/elixir-nx/nx), [Ortex](https://github.com/elixir-nx/ortex), [Bumblebee](https://github.com/elixir-nx/bumblebee), [Silero VAD](https://github.com/snakers4/silero-vad)
  - [Open-Stethoscope](https://github.com/NoahIsARider/open-stethoscope), [NeuroKit2](https://github.com/neuropsychology/NeuroKit), [WFDB-Python](https://github.com/MIT-LCP/wfdb-python)
  - [Pion WebRTC](https://github.com/pion/webrtc), [Pipecat](https://github.com/pipecat-ai/pipecat), [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [LiveKit](https://github.com/livekit/livekit)

---

## Verification & Distribution Pipeline

| Stage | Command | What It Proves |
| --- | --- | --- |
| **Inner Dev Loop (Source Poncho)** | `mix ci` & `mix monorepo.dialyzer` | Fast parallel child checks across `core/*` and `apps/*` via Blitz with zero projection overhead. |
| **SDK Artifact Projection** | `mix weld.inspect`, `mix weld.project`, `mix weld.verify` | Projects `core/{med_core, med_rtc, med_web}` into one `:med_ex` OTP app (`dist/monolith/med_ex`), compiles, tests, builds docs, and runs `mix hex.build`. |
| **Tracked Projection / Release** | `mix weld.release.prepare` & `mix weld.release.track --push` | Publishes the verified `:med_ex` projection onto orphan branch `projection/med_ex` so downstream consumers (`med_fabric/apps/exam`) resolve one `:med_ex` package from private Git (and later Hex) with identical app identity locally via Mix Workspace Ops. |

*(Future Weld optimization: fingerprint inputs—selected sources, dependency locks, manifest, shipped assets, and toolchain inputs—before projection so unchanged local projections can be verified and reused safely while keeping fresh clean-consumer builds for release candidates.)*

## Workspace Commands

```bash
mix deps.get
mix monorepo.deps.get
mix ci
mix monorepo.dialyzer
mix weld.inspect
mix weld.verify
mix weld.release.prepare
mix weld.release.track --push
```

## Security & Regulatory Boundary

WebRTC DTLS-SRTP provides transport encryption in transit, which is necessary but insufficient for HIPAA/FDA compliance. `MedEx` enforces short-lived per-session DTLS certificates, role-scoped signaling tokens, transient RAM-only media by default unless an audited capture command runs, and SaMD advisory envelopes (`advisory_only: true`, `model_sha256`, `signal_quality_score`, `integrity_state`) on all inference outputs.

## License

MIT — see [LICENSE](LICENSE).
