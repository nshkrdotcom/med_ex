# Changelog

## 0.2.0 (unreleased)

- Add optional diagnostic device selection and a pre-stream track settings callback.
- Derive a bounded frame window from the 300 ms acknowledgement budget and expose peak buffer and delay measurements.
- Accept fresh per-connection ICE configuration and show preview replacement in the hook.

## 0.1.0

- Added `MedEx.Web.asset_path/1` and packaged browser assets (`session_hook.js`,
  `pcm_capture.js`, and `pcm_worklet.js`) for LiveView preview hooks and
  AudioWorklet PCM16LE capture.
