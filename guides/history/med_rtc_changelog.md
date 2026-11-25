# Changelog

## 0.2.0

- Move encoder startup and lifecycle out of Capture callbacks into a bounded,
  disposable preview session with explicit replacement and teardown.
- Extract frame admission and preview clock rules; expose strict canonical WAV
  header validation for host artifact verification.
- Include `MedEx.Web` and its three browser assets in this source project,
  together with Node regressions and an asset lookup test.
- Support diagnostic input selection, observed settings before streaming, a
  bounded acknowledgement window, and fresh per-connection ICE configuration
  in the consolidated browser helpers.
- Limit capture writes and finish to the owner. Signal subscriber replacement.
- Add `:ice_transport_policy` to `MedEx.Preview.answer/2`.
- Remove the unused internal whole-WAV encoding and RIFF import helpers.

## 0.1.0

- Implemented `MedEx.Capture`, `MedEx.Evidence`, and `MedEx.Preview` for indexed
  48 kHz mono PCM16LE WAV recording and independent live Opus/WebRTC preview.
- Added host-configurable `:ice_servers` and bounded `Membrane.Opus.Encoder`
  preview isolation.
