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

`med_adapters` defines the **behaviour-driven adapter contracts and isolated clinical OSS integrations** for the [MedEx](../../README.md) framework.

Rather than leaking NIFs, Python subprocesses, FHIR HTTP payloads, or external SFU protocols into `med_core` or `med_rtc`, every external capability sits behind a narrow Elixir `@behaviour` with explicit timeouts, fault isolation, and SaMD advisory metadata.

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
- `integrity_state` — Snapshot of `MedCore.SignalIntegrity` for the input window (UI suppresses display if `integrity_state != :validated`)

### 2. Biosignal Sidecar Workers (`MedAdapters.Biosignal`)

Wraps established clinical signal-processing toolkits behind supervised Erlang `Port`s (or gRPC pools) using length-prefixed binary frames (CBOR/MessagePack), strict per-request timeouts, and supervisor restart budgets:

- **NeuroKit2** (<https://github.com/neuropsychology/NeuroKit>) — Sliding 5-second ECG/PPG/RSP analysis returning R-peak offsets, HR, HRV, and Signal Quality Index (SQI).
- **WFDB-Python (MIT PhysioNet)** (<https://github.com/MIT-LCP/wfdb-python>) — Exports synchronized clinical clips into standard PhysioNet `.dat`/`.hea` WFDB records and replays MIT-BIH fixtures.

### 3. Clinical Archive Sinks (`MedAdapters.Archive`)

Asynchronous, durable clinical persistence off the real-time media hot path:

- **HAPI FHIR** (<https://github.com/hapifhir/hapi-fhir>) and **Medplum** (<https://github.com/medplum/medplum>) — Persists HL7 FHIR R4/R5 `Encounter`, `Device`, `Observation` (HR, SpO₂, screening SQI), and `DiagnosticReport` resources on clinician sign-off.
- **Orthanc** (<https://github.com/jodogne/OrthancMirror> & <https://github.com/orthanc-server/orthanc-setup-samples>) — DICOM/DICOMweb PACS archival for Archetype C remote ultrasound and imaging (Use Case #6).

### 4. Optional External Media & Voice-AI Planes (`MedAdapters.ExternalMedia`)

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
    ├── archive.ex              # @behaviour for FHIR / WFDB / DICOMweb sinks
    ├── external_media.ex       # @behaviour for optional LiveKit / Pipecat bridges
    ├── ortex_runner.ex         # Phase 1C: Ortex + Nx preprocessing bridge
    ├── neurokit_port.ex        # Phase 1C: Length-prefixed binary Port to NeuroKit2/WFDB
    └── fhir_sink.ex            # Phase 1C: HAPI FHIR / Medplum R4 exporter
```

## Related Packages

- [MedEx Workspace Overview](../../README.md)
- [MedCore (Pure Functional Core)](../med_core/README.md)
- [MedRTC (OTP Effect Runtime)](../med_rtc/README.md)
- [MedWeb (LiveView Workbench)](../med_web/README.md)
- [PulseScope (First Reference App)](../../apps/pulse_scope/README.md)
