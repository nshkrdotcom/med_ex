# Public Surface, Stability Labels, and 0.x Compatibility

## Stability Levels

- **Stable:** Public API intended for external hosts. Breaking changes require a
  minor version bump during `0.x` (and a major bump after `1.0`).
- **Provisional:** Public API under active hardening; shapes may still tighten
  in `0.x` minor releases.
- **Legacy:** Preserved for browser continuous-WAV compatibility; no new features
  will be added. Deprecation notice will precede removal by at least one minor
  release.
- **Internal:** Implementation detail (`@moduledoc false`); may change in any
  patch release.

## Module Classification

This classification is a proposal made on 2026-11-26 from module docs and usage; it is not yet enforced by tooling.

| Module | Stability | Notes |
| --- | --- | --- |
| `MedEx.Contract` | Stable | Revision-1 contract definitions |
| `MedEx.StreamSpec`, `MedEx.SampleFrame`, `MedEx.FrameFingerprint` | Stable | Core waveform and identity structs |
| `MedEx.MeasurementEvent`, `MedEx.StatusEvent`, `MedEx.IntegritySpan`, `MedEx.SegmentRef` | Stable | Event and integrity contracts |
| `MedEx.StreamCursor`, `MedEx.StreamIndex` | Stable | Pure cursor transitions and index |
| `MedEx.Wire.FrameV1`, `MedEx.Wire.Control` | Stable | `MEX1` binary framing and `medex.device.v1` JSON |
| `MedEx.Serialization`, `MedEx.CanonicalJSON` | Stable | `MEJ1` canonical encoding |
| `MedEx.ClockAlign`, `MedEx.ControlInterlock` | Stable | Rational clock bounds and command interlock |
| `MedEx.StreamWriter` | Stable | Host-owned fenced stream writer |
| `MedEx.Storage`, `MedEx.Storage.File` | Stable | Storage behaviour and POSIX file backend |
| `MedEx.PreviewProvider`, `MedEx.RTCProvider` | Provisional | Optional media provider behaviours |
| `MedEx.Capture`, `MedEx.Evidence`, `MedEx.Wav`, `MedEx.Format.Wav`, `MedEx.Web`, `MedEx.Preview`, `MedEx.Preview.Clock` | Legacy | Browser 48 kHz mono PCM16LE WAV facade |
| Internal helpers (`@moduledoc false`, e.g. `ContractRules`, `PreviewSession`) | Internal | Private implementation details; may change in any patch |

## 0.x Compatibility Rules

1. **Patch releases (`0.2.x`):** Bug fixes, additive options (such as
   `checkpoint_ms: :manual`), and docs only. Must not break existing callers or
   previously qualified provider packages (`med_ex_opus`, `med_ex_rtc`).
2. **Minor releases (`0.x.0`):** May tighten provisional contracts or deprecate
   legacy modules, with migration notes in `CHANGELOG.md`.
3. **Frozen predecessor import:** Streams sealed under revision-1 `MEX1`/`MEJ1`
   remain readable by `MedEx.Storage.File.recover/2` across `0.x` releases.
4. **Provider compatibility:** Provider packages declare normal Hex requirements
   on `:med_ex` (e.g., `~> 0.2.0`) and are qualified against base patch releases.
