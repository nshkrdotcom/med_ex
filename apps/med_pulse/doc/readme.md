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

`med_pulse` is the minimal standalone reference application inside [MedEx](../../README.md). It proves that a consumer can use `med_core`, `med_rtc`, and `med_web` directly—with `encounter_ref: nil`—without adopting `med_fabric`'s encounter workflow, outbox store, or FHIR stack.

---

## What This Owns (and Does Not Own)

**`med_pulse` owns:**
- `MedPulse.ClinicalProfile` — Example `MedCore.Profile` declaring a server-terminated auscultation + talkback + telemetry + control stream profile.
- `test/med_pulse_test.exs` — Standalone proof replaying a 4 kHz PCM WAV (real PhysioNet CirCor `2530_AV.wav` when cached, else encoded 4 kHz PCM) through `MedRTC.WavCapture` and `MedRTC.SessionServer`, dropping the live preview mid-capture, deduplicating redelivered `capture_completed` events, and confirming `encounter_ref == nil`.

**`med_pulse` does not own:**
- Production clinical workflows, Phoenix exam UI, clinician observation acceptance, or FHIR exports. Those live in `med_fabric/apps/exam`.

---

## Commands & Verification

```bash
cd apps/med_pulse
mix test
mix credo --strict
mix dialyzer --force-check
```

## Related Packages

- [MedEx Workspace](../../README.md)
- [MedCore](../../core/med_core/README.md)
- [MedRTC](../../core/med_rtc/README.md)
- [MedWeb](../../core/med_web/README.md)
- [MedAdapters](../../core/med_adapters/README.md)
