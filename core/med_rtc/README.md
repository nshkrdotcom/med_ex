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

Internal capture, WebRTC transport, and browser assets for [MedEx](../../README.md).

Provides `MedEx.Capture` (indexed 48 kHz mono PCM16LE WAV writer), a bounded
preview session that owns the private `Membrane.Opus.Encoder` pipeline,
`MedEx.Evidence` (finalized artifact struct), and `MedEx.Preview` (replaceable
send-only `ExWebRTC` peer). `MedEx.Wav` owns the canonical WAV header contract.

`MedEx.Web.asset_path/1` locates the packaged browser assets `session_hook.js`,
`pcm_capture.js`, and `pcm_worklet.js`. Their paths remain under
`priv/static/med_web/`; the browser helpers and their Node tests live alongside
the Elixir SDK in this project.

Weld projects this source project into the single `:med_ex` Hex package. The
host continues to own its capture supervisor and signaling processes; MedEx
does not start an application supervision tree.
