# med_ex v0.2.0 - API Reference

## Modules

- [MedEx.Capture](MedEx.Capture.md): GenServer that writes indexed mono 48 kHz PCM16LE audio to an immutable,
content-addressed WAV file and fans full frames out to a bounded live Opus
preview branch.
- [MedEx.Evidence](MedEx.Evidence.md): Finalized evidence returned by `MedEx.Capture.finish/1` for a continuous mono
48 kHz PCM16LE WAV acquisition.
- [MedEx.Preview](MedEx.Preview.md): One replaceable, send-only WebRTC peer for an Opus preview. The caller owns
the peer and receives its ExWebRTC state changes. Capture has its own lifetime.

- [MedEx.Preview.Clock](MedEx.Preview.Clock.md): Tracks an unwrapped 48 kHz RTP media clock across captures for one preview peer.
- [MedEx.Wav](MedEx.Wav.md): Header layout for canonical MedEx PCM WAV files.
- [MedEx.Web](MedEx.Web.md): Locates MedEx's packaged browser JavaScript assets.

