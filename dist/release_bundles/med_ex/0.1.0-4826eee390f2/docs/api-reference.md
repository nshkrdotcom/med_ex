# med_ex v0.1.0 - API Reference

## Modules

- [MedRTC](MedRTC.md): WebRTC preview and recording over independent lifetimes.
- [MedRTC.Preview](MedRTC.Preview.md): One replaceable, send-only WebRTC peer for an Opus preview. The caller owns
the peer and receives its ExWebRTC state changes. Capture has its own lifetime.

- [MedRTC.WavCapture](MedRTC.WavCapture.md): Replays a finite mono PCM16 WAV and its prepared 20 ms Opus preview.
Recording integrity describes the retained file payload. Each final artifact
is identified by its canonical WAV digest and its decoded PCM digest.

- [MedWeb](MedWeb.md): Reusable Phoenix signaling contract (`MedWeb.Signaling`) and shipped browser
`RTCPeerConnection` hook assets for MedEx live sessions.

- [MedWeb.Signaling](MedWeb.Signaling.md): Locates the browser hook in a source child or the released SDK.

