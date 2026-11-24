# Medical-device product horizon

## Position and research basis

MedEx is a framework for **faithful device evidence and explicit technical state**, with optional transports and derived views. Its medical specificity comes from units/calibration, acquisition boundaries, device and configuration identity, quality/status, uncertain time, durable source lineage and safe-to-interpret failure semantics. It is not an EMR, a diagnosis engine, an arbitrary streaming platform or a substitute for a device's safety functions.

Research was checked against primary sources on November 24, 2026. FHIR distinguishes measurements, devices and provenance; DICOM represents synchronized waveform groups and channel calibration; IHE SDPi distinguishes reporting, alerting and external control. Those distinctions support a composable framework, but do not justify implementing every standard now. The recommendations below are architectural inferences from those interfaces, not conformance claims.

## 1. What the original twelve actually exercise

| Original candidate use case | Reusable foundation now | Later capability / additional proof |
|---|---|---|
| Digital stethoscope | Raw waveform, provenance, independent preview, configuration history | Characterize actual transducer, DSP/filter response and timing |
| Voice-based monitoring | Preserved source windows and derived-result lineage | Models, clinical validity, domain shift and human escalation |
| Multi-device telehealth exam | Multiple streams, independent clocks, acquisition grouping | Device-specific adapters and video/session coordination |
| ECG/SpO2/PPG monitoring | Waveform + sparse event families, unit/quality contracts | Long-duration scale, alert lifecycle, clinical display qualification |
| Voice assistant/intake | Independent communications/effects, explicit source linkage | Conversation/consent workflow, tool authorization and escalation |
| Ultrasound guidance | Source identity and immutable artifact-reference seam | Image/frame/video semantics, DICOM, calibration and latency qualification |
| Tele-EMS | Spool/replay, gaps, disconnected operation, bounded resources | Mobile connectivity, multi-party operations and validated field use |
| Respiratory devices | Rational rates, channels, source timing and maneuvers as events | Spirometry quality/reproducibility, flow-volume calibration |
| Speech/rehabilitation | Raw/derived separation and annotations | Task scoring and synchronized video/kinematics |
| Device troubleshooting | Authenticated identity, status, command audit and unknown outcome | Vendor diagnostics, privileges, maintenance and servicing policy |
| Hearing/assistive fitting | Absolute-setting reconciliation and configuration lineage | Calibrated output limits and device-specific fitting safeguards |
| Clinical training/guidance | Source-anchored annotations and review provenance | Multi-party permissions, telestration and learning assessment |

The candidates' “zero rewrites for all future devices” claim is rejected. Stable coordinates and ports reduce migration cost; they cannot pre-validate new signal families or therapeutic behavior.

## 2. Beyond those twelve

The following cases pressure-test contracts rather than create immediate projects.

| Device/workflow family | Distinct requirement exposed | Foundation needed now | Build only when exercised |
|---|---|---|---|
| Blood-pressure cuff | Discrete maneuver, multiple results, motion/cuff status | Sparse measurement, grouped metrics, quality and raw payload | Cuff cycle/abort adapter, profile validation |
| Glucose meter | Stored records, patient/specimen context, units | Event identity, measured versus received time, provenance | Meter record mapping and specimen workflow |
| Continuous glucose monitor | Session warm-up, trend/status, calibration changes | Epoch/descriptor changes, unavailable values, calibration references | CGM session adapter and trend interpretation |
| Thermometer and scale | Intermittent decimal values, measurement site/method | Exact numeric representation, coded units, source method | Device-specific method/profile implementation |
| EEG/EMG/evoked potentials | Many channels, triggers, high-rate synchronous groups | Channel order, rational rate, raw native integers, event anchors | High-channel load benchmarks and neurological display |
| Polysomnography | Overnight heterogeneous rates and scoring revisions | Per-stream clocks, long-lived provenance, immutable revisions | Long-duration storage, sleep scoring and study workflow |
| Fetal monitoring | Maternal/fetal association, multiple source identities | Unambiguous device/stream identity, association provenance | Subject association, CTG workflow and domain-specific safety review |
| Ventilator/CPAP | Waveforms plus mode/settings/status/alarm states | Event/waveform separation and honest configuration epochs | Vendor mode semantics and verified alarm lifecycle |
| Infusion/insulin pump | High-consequence actuation and drug/dose context | Audit IDs and unknown-outcome semantics only | Device interlocks, local authority, hazard controls and separate validation |
| Dialysis equipment | Multiple coupled fluid/pressure measurements and treatment state | Channels, units, events and independent failure reporting | Treatment model and safety-critical integration |
| Implantable-device telemetry | Intermittent privileged sessions and device-specific histories | Authenticated identity, explicit reconnect/boot/history boundaries | Programmer protocol, local safety authority and specialist workflow |
| Neurostimulation/prosthetic control | Tight actuation deadlines and patient-specific configuration | Preserve configuration facts and measured timing limits | Dedicated real-time/safety architecture; BEAM network control alone is insufficient |
| Point-of-care/lab analyzers | Specimen, reagent lot, QC/calibration and amended result | Opaque provenance references, immutable original results | Specimen/QC model in Fabric or another host, instrument protocol |
| Coagulation and rapid-test readers | Noncontinuous results with test validity | Sparse missing/invalid values, lot/decoder references | Test-specific quality rules and result interpretation |
| Gait/rehabilitation IMUs | Multiaxis motion, orientation frames, transforms | Typed channels and raw-versus-derived lineage | Coordinate systems, fusion algorithms and biomechanics validation |
| Home medication/adherence devices | Event histories and uncertain user action | Observed event versus inferred action; replay identity | Adherence workflow; never infer ingestion from a lid-open event |
| Ophthalmic/dermatoscopic imaging | Large files, color/geometry calibration and acquisition context | Artifact-reference/provenance seam | Image upload/resume, image schemas and clinical viewing |
| Connected surgical/robotic tools | Real-time actuation and coordinated authority | Honest command and timing records only | Separately engineered local safety control; not this framework's initial runtime |

These are more demanding variations than adding modality atoms. Some require a new schema family or a specialized system outside MedEx. The SDK must fail explicitly on an unsupported encoding/control operation rather than pretending generic support.

## 3. Foundations built now

Build only what the two slices and compatibility requirements exercise: public application identity; real optional media boundaries; regular waveform and sparse measurement/event contracts; immutable descriptors; calibration/processing provenance; sample/epoch coordinates; rational time and bounded alignment; explicit integrity spans; bounded per-stream admission; durable journal and spool replay; honest command reconciliation; immutable review references; codec/transport/storage/source behaviors; headless and native-sidecar deployments.

Metadata must represent unknowns now. A sensor whose sample-to-clock anchor is unqualified still records evidence; alignment remains unavailable. A scale with unknown calibration records native values/status but does not manufacture calibrated physical units. A future adapter cannot retroactively upgrade old evidence by changing a display label.

Use separate channels only when they are synchronously sampled with common rate/layout. A device with asynchronous sources emits multiple streams. A result with no meaningful sample index uses the sparse family. An image belongs in an artifact/image extension, not a fake one-sample waveform.

## 4. Capability stages and exit criteria

| Stage | Scope | Exit criterion |
|---|---|---|
| A — this plan | Software contracts; two simulated workflows; optional preview; legacy behavior | All implementation gates, separate-process network/fault tests and honest evidence labels |
| B — first physical device | One named stethoscope/ECG or PLX device path | Hardware captures compared to known input; transport/decoder conformance; loss, restart, drift, calibration and latency characterized |
| C — operational use | Several sources and longer acquisitions | Defined load/retention/security/support model; durable backup/restore; deployment validation |
| D — clinical or regulated feature | Intended clinical workflow and applicable jurisdiction | Separate risk, usability, clinical performance and regulatory work, appropriate to the actual intended use |
| E — higher-risk control/AI | Treatment actuation, alerts or derived clinical decisions | Dedicated hazards and controls, validation of algorithm/device behavior, human authority and failure handling |

Stage A does not automatically authorize Stage B–E. Nevertheless, Stage A should be useful engineering software: actual sockets, real persistence, operators reviewing records, and failures that can be reproduced and inspected.

## 5. Deliberate exclusions

No universal FHIR model in the SDK; no DICOM parser, Bluetooth radio stack, Nerves image, distributed clock service, event-sourcing framework, workflow language, dynamic plugin registry, generic alarm router, universal device-control API, compiled dependency cache, or portfolio tooling expansion. Add one only when a concrete consumer establishes a need and a smaller adapter is insufficient.

Reference implementations use standard libraries at effect boundaries. Native hardware/Nerves clients reuse values, protocol/decoder tests and source/spool contracts, but may substitute storage and transport. Real-time acquisition deadlines and local safety remain the device's responsibility; ordinary Elixir networking is not a hard-real-time guarantee.

## Research references

- [HL7 FHIR R4 Observation](https://hl7.org/fhir/R4/observation-definitions.html): typed results, components, device references and missing-value representation. Fabric retains R4 because the snapshot already uses it; do not silently upgrade exchange versions.
- [HL7 FHIR R4 Provenance](https://hl7.org/fhir/R4/provenance.html): origin/process assertions belong with the resource lineage; they are distinct from merely recording access events.
- [DICOM waveform module](https://dicom.nema.org/medical/dicom/2022e/output/chtml/part03/sect_C.10.9.html) and [synchronization module](https://dicom.nema.org/medical/dicom/2024c/output/chtml/part03/sect_C.7.4.2.html): channel grouping, calibration and explicit temporal reference. These fixed-version references motivate the horizon, not a DICOM implementation claim.
- [IHE SDPi technical framework](https://profiles.ihe.net/DEV/SDPi/): separately profiles device reporting, alerting and external control, including waveform and synchronized-time use cases.
- Bluetooth SIG [Pulse Oximeter Service 1.0.1](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/PLXS_v1.0.1/out/en/index-en.html), [Blood Pressure Service 1.1.1](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/BLS_v1.1.1/out/en/index-en.html), and [Continuous Glucose Monitoring Service 1.0.2](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/CGMS_v1.0.2/out/en/index-en.html): sparse results, device status and stored/session data differ from raw audio.
- [FDA interoperable-device design guidance](https://www.fda.gov/regulatory-information/search-fda-guidance-documents/design-considerations-and-pre-market-submission-recommendations-interoperable-medical-devices): interface, performance and verification considerations inform the boundary between software simulation evidence and validation of an intended device use. This docset does not make a compliance determination.
