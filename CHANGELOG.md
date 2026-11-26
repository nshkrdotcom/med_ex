# Changelog

## 0.2.0 — 2026-11-25

- Consolidate live Opus encoding by removing the Membrane framework dependencies and running a small C11 `libopus` 1.5.2 encoder in its own OS process over an Erlang `Port` (`elixir_make`), preserving the `MedEx.Opus.Provider` behaviour and timeouts.
- Verify the pinned Xiph `opus-1.5.2.tar.gz` SHA-256 before extraction, caching downloads outside `_build` and supporting offline builds via `MED_EX_OPUS_TARBALL`.
- Bound native hello startup, reject truncated packet headers and invalid packet responses, and cover real provider shutdown and owner-loss cleanup.
- Require absolute offline tarball paths, fail without network access when an explicit tarball is missing, reject an unset `MIX_APP_PATH`, and rebuild after native Makefile changes; add executable protocol and Make boundary regressions.
- Require `med_ex ~> 0.3.0`.

## 0.1.0 — 2026-11-24

- Add the Membrane-backed Opus provider for 48 kHz mono PCM16LE preview.
- Integrate with MedEx `~> 0.2.0`.
