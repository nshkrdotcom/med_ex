<p align="center">
  <img src="assets/med_adapters.svg" width="200" height="200" alt="MedAdapters logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex">
    <img alt="GitHub: med_ex" src="https://img.shields.io/badge/GitHub-med_ex-0b0f14?logo=github" />
  </a>
  <a href="LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# MedAdapters

`med_adapters` defines the **behaviour-driven adapter contracts and isolated real-time signal, AI, and external media integrations** for the [MedEx](../../README.md) framework.

> **Packaging & Ownership Boundary**:
> - `med_adapters` is currently an **opt-in source project excluded from the default welded `:med_ex` SDK projection** (`internal_only` in `build_support/weld.exs`). It is intentionally **not** separately published yet: once a concrete adapter ships, we will verify that a clean consumer can combine it with the published `:med_ex` SDK through `:med_ex`'s public API without pulling duplicate `MedCore` modules.
> - `med_adapters` is scoped strictly to **real-time signal/AI compute and external media planes**. Durable clinical observation persistence, transactional outbox retry, and HL7 FHIR (plus future DICOM) delivery live in `med_fabric` (`mf_store` and `mf_interop`).

---

## Adapter Behaviours & Vetted OSS Ecosystem

### 1. In-BEAM Inference (`MedAdapters.Inference`)

Runs compact neural models directly inside the BEAM on dirty CPU schedulers with sub-10 ms latency and zero Python serialization overhead:

- **Nx** (<https://github.com/elixir-nx/nx>) — Numerical tensor preprocessing (e.g., deterministic log-mel spectrograms verified numerically against `librosa`).
- **Ortex** (<https://github.com/elixir-nx/ortex>) — Rust ONNX Runtime NIF bindings.
- **Open-Stethoscope ONNX** (<https://github.com/NoahIsARider/open-stethoscope>) — 404K-parameter (1.6 MB ONNX) heart-murmur & auscultation position-QC classifier trained on PhysioNet-2022 CirCor.
- **Silero VAD ONNX** (<https://github.com/snakers4/silero-vad>) — ~2 MB MIT Voice Activity Detector (`< 1 ms` per 30 ms chunk) for full-duplex Archetype D barge-in and separating clinician speech from diagnostic silence/coughing.
- **Bumblebee** (<https://github.com/elixir-nx/bumblebee>) — Optional in-BEAM Whisper ASR transcription on Axon/EXLA.

#### SaMD Advisory Guardrail Contract

Every inference result returned by `MedAdapters.Inference` MUST emit an envelope carrying:

- `advisory_only: true`
- `model_sha256` — Cryptographic digest of the exact loaded ONNX weights
- `signal_quality_score` — Position/signal quality index for the analyzed window
- `integrity_state` — Snapshot of `MedCore.Session` integrity for the input window (UI suppresses display if `integrity_state != :validated`)

### 2. Biosignal Sidecar Workers (`MedAdapters.Biosignal`)

Wraps established clinical signal-processing toolkits behind supervised Erlang `Port`s (or gRPC pools) using length-prefixed binary frames (CBOR/MessagePack), strict per-request timeouts, and supervisor restart budgets:

- **NeuroKit2** (<https://github.com/neuropsychology/NeuroKit>) — Sliding 5-second ECG/PPG/RSP analysis returning R-peak offsets, HR, HRV, and Signal Quality Index (SQI).
- **WFDB-Python (MIT PhysioNet)** (<https://github.com/MIT-LCP/wfdb-python>) — Reads MIT-BIH / PhysioNet fixtures and formats waveform capture artifacts into standard `.dat`/`.hea` WFDB files.

### 3. Optional External Media & Voice-AI Planes (`MedAdapters.ExternalMedia`)

- **LiveKit** (<https://github.com/livekit/livekit>) — Optional external Go SFU adapter when Use Case #12 clinical training scales to hundreds of simultaneous observers.
- **Pipecat** (<https://github.com/pipecat-ai/pipecat>) and **whisper.cpp** (<https://github.com/ggml-org/whisper.cpp>) — Full conversational voice-AI pipelines for Use Cases #2 and #5 bridged over WebRTC/gRPC with deterministic clinician escalation back into `med_rtc`.

---

## Planned Module Layout

```text
core/med_adapters/lib/
├── med_adapters.ex
└── med_adapters/
    ├── inference.ex            # @behaviour + AdvisoryResult envelope
    ├── biosignal.ex            # @behaviour for supervised Port/gRPC biosignal workers
    ├── external_media.ex       # @behaviour for optional LiveKit / Pipecat bridges
    ├── ortex_runner.ex         # Phase 1C: Ortex + Nx preprocessing bridge
    └── neurokit_port.ex        # Phase 1C: Length-prefixed binary Port to NeuroKit2/WFDB
```

## Related Packages

- [MedEx Workspace Overview](../../README.md)
- [MedCore (Pure Functional Core)](../med_core/README.md)
- [MedRTC (OTP Effect Runtime)](../med_rtc/README.md)
- [MedWeb (LiveView Workbench)](../med_web/README.md)
- [MedPulse (Minimal SDK Reference App)](../../apps/med_pulse/README.md)
