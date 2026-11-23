# Changelog

## 0.2.0 (unreleased)

- Limit capture writes and finish to the owner. Signal subscriber replacement.
- Add `:ice_transport_policy` to `MedEx.Preview.answer/2`.
- Remove the unused internal whole-WAV encoding and RIFF import helpers.

## 0.1.0

- Implemented `MedEx.Capture`, `MedEx.Evidence`, and `MedEx.Preview` for indexed
  48 kHz mono PCM16LE WAV recording and independent live Opus/WebRTC preview.
- Added host-configurable `:ice_servers` and bounded `Membrane.Opus.Encoder`
  preview isolation.
