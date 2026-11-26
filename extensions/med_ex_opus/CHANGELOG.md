# Changelog

## 0.2.0 — 2026-11-26

- Replace the Membrane pipeline with a small C encoder run as an OS process over
  a Port, linked against a vendored, checksum-verified libopus 1.5.2. Drop all
  `membrane_*` dependencies; add `elixir_make`.
- Behaviour and timeouts of `MedEx.Opus.Provider` are unchanged.

## 0.1.0 — 2026-11-24

- Add the Membrane-backed Opus provider for 48 kHz mono PCM16LE preview.
- Integrate with MedEx `~> 0.2.0`.
