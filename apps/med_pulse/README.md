<p align="center">
  <img src="assets/med_pulse.svg" width="200" height="200" alt="MedPulse logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex">
    <img alt="GitHub: med_ex" src="https://img.shields.io/badge/GitHub-med_ex-0b0f14?logo=github" />
  </a>
  <a href="LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# MedPulse

`med_pulse` is the **minimal standalone SDK reference application** inside the [MedEx](../../README.md) workspace.

Its job is intentionally narrow: prove that an independent consumer can adopt the `:med_ex` public API without adopting `med_fabric`'s durable encounter workflow, PostgreSQL outbox, or FHIR stack. Full clinical product workflows (connected examination, clinician review/acceptance, and full stethoscope products) live in `med_fabric`.

---

## First Reference Slice (Before Hardware-Specific Transport Optimization)

The first executable proof in `med_pulse` exercises the canonical reconnect & duplicate-delivery contract defined in [`core/med_core/README.md`](../../core/med_core/README.md):

1. Open a **two-browser WebRTC talkback session** (`session_id`) with a deterministic simulated capture (`acquisition_id`, `encounter_ref: nil`).
2. Drop the listener's live preview (`connection_id: "conn_a"`) while simulated capture continues independently.
3. Rejoin the browser to the same `session_id` (`connection_id: "conn_b"`).
4. Deliver `capture_completed` twice and confirm the reference UI renders:
   - the live preview interruption interval separately from
   - the recording artifact's independently measured continuity (`:observed_continuous | :observed_gap | :unknown`), and
   - one deduplicated finalized capture.

Hardware-specific diagnostic transport choices (such as 4 kHz uncompressed PCM over `ex_sctp` DataChannels for auscultation, or 250 Hz ECG framing + `Ortex`/`NeuroKit2` hooks) are sketched in `MedPulse.ClinicalProfile` as a target multi-stream profile and will be exercised in focused transport checks once a concrete device path requires them.

---

## Target Multi-Stream Profile Skeleton (`MedPulse.ClinicalProfile`)

| Stream ID | Archetype | Modality | Target Codec / Framing | Priority |
| --- | --- | --- | --- | --- |
| `"device_control"` | `:control` | `:stethoscope` | `{:cbor_signed, MedPulse.ControlSchema}` | `0` |
| `"vitals_telemetry"` | `:telemetry` | `:ecg` | `{:binary_frame, MedPulse.VitalsFrame}` | `1` |
| `"auscultation"` | `:diagnostic_audio` | `:stethoscope` | `{:pcm_s16le, 4_000}` | `2` |
| `"talkback_voice"` | `:interactive_media` | `:voice` | `{:opus, bitrate: 32_000, fec: true, dtx: true}` | `3` |

## Related Packages

- [MedEx Workspace Overview](../../README.md)
- [MedCore (Pure Functional Core)](../../core/med_core/README.md)
- [MedRTC (OTP Effect Runtime)](../../core/med_rtc/README.md)
- [MedWeb (LiveView Workbench)](../../core/med_web/README.md)
- [MedAdapters (Opt-In Signal & Media Ports)](../../core/med_adapters/README.md)
