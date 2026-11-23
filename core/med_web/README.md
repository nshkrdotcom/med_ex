<p align="center">
  <img src="assets/med_web.svg" width="200" height="200" alt="MedWeb logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex">
    <img alt="GitHub: med_ex" src="https://img.shields.io/badge/GitHub-med_ex-0b0f14?logo=github" />
  </a>
  <a href="LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# med_web

Internal browser assets package for [MedEx](../../README.md).

Provides `MedEx.Web.asset_path/1` to locate the three packaged JavaScript assets
(`session_hook.js`, `pcm_capture.js`, and `pcm_worklet.js`) for LiveView preview
signaling and browser `AudioWorklet` PCM16LE capture. Projected with
`core/med_rtc` into the single `:med_ex` Hex package.

See the [host integration guide](../../guides/host_integration.md).
