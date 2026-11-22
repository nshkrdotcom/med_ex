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

`med_adapters` is an **opt-in source package** inside [MedEx](../../README.md) defining behaviour contracts for real-time signal analysis and advisory ML inference. It is intentionally excluded from the default Welded `:med_ex` SDK projection (`internal_only` in `build_support/weld.exs`) so consumers do not inherit heavy ML or sidecar dependencies unless they explicitly opt in.

---

## What This Owns (and Does Not Own)

**`med_adapters` owns:**
- `MedAdapters.Inference` — `@behaviour` and `advisory_result` type carrying `advisory_only: true`, `model_sha256`, `signal_quality_score`, and `continuity` unified directly onto `MedCore.Session.continuity_state()` (`:observed_continuous | :observed_gap | :unknown`).
- Future opt-in adapters for in-BEAM ONNX inference (`Ortex`/`Nx`), supervised Python biosignal Ports (`NeuroKit2`, `wfdb-python`), or external media planes (`LiveKit`, `Pipecat`).

**`med_adapters` does not own:**
- Clinical persistence, outbox retries, or HL7 FHIR / DICOM delivery (those live in `med_fabric`'s `mf_store` and `mf_interop`).

---

## Walkthrough

```elixir
@behaviour MedAdapters.Inference

# Every inference output carries explicit advisory provenance and recording continuity:
%{
  advisory_only: true,
  model_sha256: "sha256_of_onnx_weights",
  signal_quality_score: 0.94,
  continuity: :observed_continuous,
  findings: %{murmur_probability: 0.12}
}
```

See `lib/med_adapters/inference.ex` and `test/med_adapters_test.exs`.

---

## Commands & Verification

```bash
cd core/med_adapters
mix test
mix credo --strict
mix dialyzer --force-check
```

## Candidate Upstream Ecosystem (Opt-In Future Adapters)

- Nx: https://github.com/elixir-nx/nx
- Ortex: https://github.com/elixir-nx/ortex
- Open-Stethoscope: https://github.com/NoahIsARider/open-stethoscope
- Silero VAD: https://github.com/snakers4/silero-vad
- NeuroKit2: https://github.com/neuropsychology/NeuroKit
- WFDB-Python: https://github.com/MIT-LCP/wfdb-python
- LiveKit: https://github.com/livekit/livekit
- Pipecat: https://github.com/pipecat-ai/pipecat

## Related Packages

- [MedEx Workspace](../../README.md)
- [MedCore](../med_core/README.md)
- [MedRTC](../med_rtc/README.md)
- [MedWeb](../med_web/README.md)
- [MedPulse](../../apps/med_pulse/README.md)
