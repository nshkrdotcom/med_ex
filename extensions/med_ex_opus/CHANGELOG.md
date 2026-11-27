# Changelog

## 0.3.0 - 2026-11-26

### Breaking changes

- Replace the layered encoder with one owner-bound Provider GenServer and Port.
- Remove the base SDK dependency and provider behavior/discovery mechanisms.
- Enforce bounded hello/encode deadlines, exact operation identity, one pending
  request and native cleanup on owner loss, malformed output and uncertainty.
- Validate pinned archive and build-input identity before warm output reuse;
  retain the pinned libopus OS-process isolation and source-only distribution.
- Publish directly from this Mix project; no provider Weld projection.

### Tests and documentation

- Cover native build/cache failure, protocol validation and concrete lifecycle.
- Document independent installation and exact native/detached release gates.

## 0.2.1 — 2026-11-26

- Build the test decoder with the configured compiler and support compiler wrappers.
- Retry the alternate Opus mirror after checksum failure, terminate the Linux codec on supervisor death, and run provider decode tests against the pinned static library.
- Supervise the native codec child through port closure so a stopped or hung codec is killed and reaped. Track a single linked encoder in the standalone provider.
- Reject whitespace in the Mix application build path before build or clean recipes run. Verify downloaded archives before publishing them to the cache so failed downloads can be retried.
- Exercise the built encoder with a real tone and check decoded sample count and energy in provider tests and consumer qualification.

## 0.2.0 — 2026-11-25

- Consolidate live Opus encoding by removing the Membrane framework dependencies and running a small C11 `libopus` 1.5.2 encoder in its own OS process over an Erlang `Port` (`elixir_make`), preserving the `MedEx.Opus.Provider` behaviour and timeouts.
- Verify the pinned Xiph `opus-1.5.2.tar.gz` SHA-256 before extraction, caching downloads outside `_build` and supporting offline builds via `MED_EX_OPUS_TARBALL`.
- Bound native hello startup, reject truncated packet headers and invalid packet responses, and cover real provider shutdown and owner-loss cleanup.
- Require absolute offline tarball paths, fail without network access when an explicit tarball is missing, reject an unset `MIX_APP_PATH`, and rebuild after native Makefile changes; add executable protocol and Make boundary regressions.
- Require `med_ex ~> 0.3.0`.

## 0.1.0 — 2026-11-24

- Add the Membrane-backed Opus provider for 48 kHz mono PCM16LE preview.
- Integrate with MedEx `~> 0.2.0`.
