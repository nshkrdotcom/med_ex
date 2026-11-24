# Medical-Device Product Horizon

## Architectural Position

`MedEx` is an SDK for **source-preserving medical-device evidence and explicit technical state**, paired with optional media providers. Its medical-device specificity comes from exact units and calibration (or explicit `:unknown`), immutable acquisition and configuration descriptors, per-sample and per-epoch coordinates, explicit missing-value and status semantics, bounded clock uncertainty, durable source lineage across disconnects, and fail-closed command interlocks.

`MedEx` is deliberately **not** an EHR/EMR, a clinical decision-support or diagnostic inference engine, a generic media-streaming platform, or a substitute for hardware/firmware safety controls.

Architectural boundaries in `MedEx` draw from primary healthcare and device interoperability specifications—including HL7 FHIR R4 (`Observation` vs `Device` vs `Provenance`), DICOM Waveform and Synchronization modules, IHE SDPi (separating reporting, alerting, and external control), and Bluetooth SIG medical GATT profiles (`PLXS`, `BLS`, `CGMS`). Those specifications inform the SDK's data seams so downstream hosts can map reviewed evidence faithfully; `MedEx` itself does not claim turnkey standards or regulatory conformance.

## 1. Initial Connected-Care And Diagnostic Use Cases

| Use Case | Foundation Implemented In `MedEx` Today | Future Adapter / Validation Work Required |
| --- | --- | --- |
| Digital stethoscope | Lossless waveform capture, processing provenance, disposable Opus/WebRTC preview, monitor configuration lineage | Physical transducer characterization, acoustic filter frequency/phase verification, latency qualification |
| Voice-based monitoring | Preserved raw audio windows, source provenance, raw-vs-derived boundary | Validated acoustic/speech models, domain-shift monitoring, clinician escalation workflows |
| Multi-device telehealth exam | Independent per-stream descriptors, independent clocks, shared `acquisition_id` grouping | Hardware peripheral adapters, synchronized video/session orchestration |
| ECG / SpO₂ / PPG monitoring | Regular waveform (`StreamSpec` + `SampleFrame`) and sparse measurement (`MeasurementEvent`) families, calibration/status contracts | Long-duration storage retention, physiological alarm lifecycles, clinical display qualification |
| Medical voice intake / assistant | Separation of live communications from authoritative clinical records | Consent capture, tool authorization boundaries, clinician sign-off workflows |
| Ultrasound / procedural guidance | Authenticated source identity and content-addressed artifact reference seams | 2D/3D image/cine schemas, DICOM export, spatial calibration, latency budgets |
| Tele-EMS / mobile acquisition | Durable local journal, upstream spool receipts, explicit `:source_gap` spans, bounded memory/disk caps | Cellular handover testing, multi-party dispatch coordination, field environmental validation |
| Respiratory / spirometry devices | Rational sample rates, calibrated channels, maneuver/status event separation | Flow-volume loop calibration, ATS/ERS maneuver reproducibility rules |
| Speech / motor rehabilitation | Lossless source capture and sample-indexed technical spans | Task scoring protocols, synchronized kinematics/video |
| Device troubleshooting | Authenticated boot/epoch tracking, `StatusEvent`, `ControlInterlock` audit and `:outcome_unknown` | Vendor diagnostic protocols, maintenance privilege separation |
| Hearing / assistive fitting | Persist-before-dispatch setting transitions and configuration epoch lineage | Calibrated output safety ceilings and device-resident fitting safeguards |
| Clinical training / supervision | Sample-range references and immutable index digests | Multi-party role permissions, telestration, competency tracking |

Stable sample coordinates, provenance descriptors, and storage/provider behaviours minimize host rework as new peripherals are integrated, without pretending that software abstractions pre-validate new physiological modalities or therapeutic hardware.

## 2. Broader Medical-Device Families

Evaluating a wider range of medical devices clarifies what belongs in `MedEx`'s core contracts today versus what must remain future extensions or separate safety-critical systems:

| Device / Workflow Family | Distinct Requirement Exposed | Core Seam Present Today | Future Extension (Build Only When Exercised) |
| --- | --- | --- | --- |
| Blood-pressure cuff (`BLS`) | Discrete inflation maneuver, systolic/diastolic/MAP group, motion/cuff status | Multi-metric `MeasurementEvent`, `device_status`, raw bytes | Cuff maneuver/abort adapter and profile validation |
| Episodic glucose meter | Stored historical records, meal/specimen context, exact units | `source_record_id`, `device_time` vs `receipt_time`, decimal metrics | Meter historical sync protocol and specimen context in host |
| Continuous glucose monitor (`CGMS`) | Warm-up phase, calibration changes, trend/unavailable states | `source_epoch` / `config_epoch`, `{:missing, reason}`, calibration refs | CGM session lifecycle adapter and trend profiles |
| Thermometer and scale | Intermittent decimal readings, measurement site/method | Exact `{mantissa, exponent}` decimals, provenance facts | Device-specific profile adapters |
| EEG / EMG / evoked potentials | High channel counts, stimulus triggers, synchronous multichannel rows | Up to 32 interleaved channels, rational rates, `:s24le`/`:s32le` | Higher-channel-count benchmarks, trigger-event family, neuro display |
| Polysomnography | Multi-hour heterogeneous rates, multi-pass scoring revisions | Independent per-stream rates/clocks, immutable stream indexes | Multi-hour retention tiers and sleep-study scoring workflows |
| Maternal / fetal monitoring | Multi-subject physiological attribution | Explicit `source_ref` / `stream_id` and provenance facts | Maternal-fetal subject association and CTG review safety rules |
| Ventilator / CPAP | Simultaneous pressure/flow waveforms, mode settings, and alarms | Separate waveform, `StatusEvent`, and `config_epoch` models | Vendor mode schemas and verified clinical alarm lifecycles |
| Infusion / insulin pump | High-consequence drug delivery actuation | Command audit IDs and `:outcome_unknown` state tracking only | Device-resident safety interlocks, dose limits, and hazard validation |
| Dialysis equipment | Coupled fluid/pressure telemetry and treatment phases | Typed channels, exact decimals, independent status streams | Treatment state machine and safety-critical integration |
| Implantable telemetry | Intermittent privileged programmer sessions | Authenticated `source_ref`, `boot_id`, and epoch boundaries | Programmer link security, local device authority, specialist workflow |
| Neurostimulation / prosthetics | Sub-millisecond closed-loop actuation | Configuration provenance and measured timing bounds | Dedicated real-time firmware/RTOS; BEAM networking is not hard real-time |
| Point-of-care / lab analyzers | Specimen ID, reagent lot, QC lockouts, amended results | Opaque provenance facts and immutable original `MeasurementEvent` | Specimen/reagent/QC domain model in host application |
| Rapid-test / coagulation readers | Single-shot validity flags and lot calibration | `{:missing, reason}`, `device_status`, raw payload digest | Assay-specific validity and interpretation rules |
| Gait / rehabilitation IMUs | Multi-axis inertial channels and coordinate frames | Synchronous multi-channel `:s16le`/`:s32le` streams and provenance | Orientation frame conventions and sensor-fusion workers |
| Medication adherence devices | Uncertain human action vs physical sensor trigger | Observed technical event kept distinct from clinical inference | Host workflow that records sensor events without inferring ingestion |
| Ophthalmic / dermatoscopic imaging | Still frames, color/spatial calibration, large payloads | Content-addressed artifact digest and provenance patterns | Dedicated image/DICOM artifact family (never fake 1-sample waveforms) |
| Connected surgical / robotic tools | Hard real-time actuation and local operator authority | Post-hoc telemetry and command audit records only | Dedicated local real-time safety architecture outside `MedEx` |

When given an unsupported encoding, invalid descriptor, or unverified calibration, `MedEx` fails closed rather than coercing values into approximate representations.

## 3. Implemented Capabilities Versus Future Directions

### Implemented In `MedEx` Today

- Canonical `:med_ex` OTP application with zero runtime Hex dependencies and enforced pure-core / effectful-capture separation.
- Regular waveform (`StreamSpec`, `SampleFrame`, `MEX1`, `FrameFingerprint`), sparse measurement (`MeasurementEvent`), technical status (`StatusEvent`), and qualifier (`IntegritySpan`) contracts.
- Fenced per-stream `StreamWriter` with POSIX content-addressed `.pcm` segments, checksummed `stream.mejournal`, volatile-vs-durable receipts, replay/conflict handling, crash recovery, and frozen predecessor lineage import.
- Exact rational affine clock-bound solver (`ClockAlign`) and persist-before-dispatch device command state machine (`ControlInterlock`).
- Browser 48 kHz mono WAV capture (`MedEx.Capture`, `MedEx.Evidence`, `MedEx.Web`) and optional `:med_ex_opus` / `:med_ex_rtc` media providers usable in-VM or in an isolated sidecar process.

### Future Directions (Not Implemented In `MedEx` Today)

- Physical USB, serial, or Bluetooth Low Energy (BLE) hardware transport adapters and Nerves firmware packages.
- Dedicated image/cine/DICOM artifact contracts and high-channel-count (>32 channel) neurophysiology extensions.
- Out-of-band signal-processing, quality-scoring, and ML/AI inference workers consuming sealed `StreamIndex` artifacts.
- Clinical alarm routing or therapeutic device actuation frameworks.

## 4. Validation And Maturity Stages

Engineering verification of `MedEx` software contracts does not substitute for hardware or clinical validation in a downstream medical product:

| Stage | Scope | Required Evidence |
| --- | --- | --- |
| **A — Software SDK & Simulated Reference Workflows** *(current)* | Pure contracts, POSIX journaled storage/recovery, fault-injected transport/process tests, optional preview isolation, and browser WAV compatibility | Automated unit/property/vector tests, boundary checks, multi-profile consumer builds, and separate-process fault-injection qualification |
| **B — Physical Device Integration** | A specific physical stethoscope, ECG, or pulse oximeter peripheral | Bench captures against calibrated signal generators; oscillator drift, ADC scale, BLE/USB dropout, reboot, and end-to-end latency characterization |
| **C — Multi-Device Operational Deployment** | Concurrent clinical rooms, sustained retention, and production infrastructure | Load/soak testing, disk retention and backup/restore drills, key rotation, observability, and operational runbooks |
| **D — Regulated Clinical Workflow** | Intended diagnostic or monitoring use in a target jurisdiction | Risk management (e.g., ISO 14971), software lifecycle (IEC 62304), usability engineering (IEC 62366), cybersecurity, and clinical evaluation |
| **E — Higher-Risk Control Or Autonomous Analytics** | Closed-loop actuation, physiological alarms, or diagnostic AI | Dedicated hazard controls, local hardware/firmware safety authority, clinical algorithm validation, and regulatory clearance |

## 5. Deliberate Exclusions

`MedEx` intentionally excludes a built-in EHR/FHIR resource library, DICOM parser, BLE radio stack, Nerves system image, distributed consensus clock, generic workflow DSL, dynamic plugin registry, clinical alarm router, or universal therapeutic control API. Host applications such as [Med Fabric](https://github.com/nshkrdotcom/med_fabric) own clinical identity, persistence, review, and HL7 FHIR exchange at the application layer.

## Primary Standards References

- [HL7 FHIR R4 Observation](https://hl7.org/fhir/R4/observation-definitions.html) & [Provenance](https://hl7.org/fhir/R4/provenance.html) — typed measurements, components, missing-data reasons, device references, and origin lineage.
- [DICOM Waveform Module](https://dicom.nema.org/medical/dicom/2022e/output/chtml/part03/sect_C.10.9.html) & [Synchronization Module](https://dicom.nema.org/medical/dicom/2024c/output/chtml/part03/sect_C.7.4.2.html) — synchronous multiplex channel groups, channel calibration, and temporal synchronization frames.
- [IHE SDPi Technical Framework](https://profiles.ihe.net/DEV/SDPi/) — separation of device reporting, alerting, and external control.
- Bluetooth SIG [Pulse Oximeter Service 1.0.1](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/PLXS_v1.0.1/out/en/index-en.html), [Blood Pressure Service 1.1.1](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/BLS_v1.1.1/out/en/index-en.html), and [Continuous Glucose Monitoring Service 1.0.2](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/CGMS_v1.0.2/out/en/index-en.html) — sparse indications, RACP stored-record replay, and measurement/sensor status bitmasks.
- [FDA Interoperable Medical Devices Guidance](https://www.fda.gov/regulatory-information/search-fda-guidance-documents/design-considerations-and-pre-market-submission-recommendations-interoperable-medical-devices) — interface contracts, failure behavior, and verification boundaries.
