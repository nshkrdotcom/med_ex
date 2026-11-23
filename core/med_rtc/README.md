<p align="center">
  <img src="assets/med_rtc.svg" width="200" height="200" alt="MedRTC logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex">
    <img alt="GitHub: med_ex" src="https://img.shields.io/badge/GitHub-med_ex-0b0f14?logo=github" />
  </a>
  <a href="LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# med_rtc

Internal media capture and WebRTC transport package for [MedEx](../../README.md).

Provides `MedEx.Capture` (indexed 48 kHz mono PCM16LE WAV writer with bounded
live `Membrane.Opus.Encoder` preview fan-out), `MedEx.Evidence` (finalized
artifact struct), and `MedEx.Preview` (replaceable send-only `ExWebRTC` peer).
Projected with `core/med_web` into the single `:med_ex` Hex package.

See the [host integration guide](../../guides/host_integration.md).
