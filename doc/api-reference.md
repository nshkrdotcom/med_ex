# med_ex v0.1.0 - API Reference

## Modules

- [MedCore](MedCore.md): Pure functional clinical signal and live-session domain core for MedEx.
- [MedCore.Profile](MedCore.Profile.md): Behaviour implemented by clinical product applications to compose MedEx
transport archetypes, streams, inference hooks, and device control policies.

- [MedCore.Session](MedCore.Session.md): Immutable live clinical transport session aggregate and pure reducer (`step/2`).
- [MedCore.StreamSpec](MedCore.StreamSpec.md): Declarative contract for a clinical media, telemetry, or device control stream.

- [MedRTC](MedRTC.md): OTP effect shell and WebRTC/Opus/SCTP runtime boundary for MedEx.
- [MedRTC.PeerLoopback](MedRTC.PeerLoopback.md): Minimal real `ExWebRTC.PeerConnection` SDP/ICE loopback harness used to
exercise live WebRTC negotiation, peer disconnect, and replacement connection
establishment against `MedRTC.SessionServer`.

- [MedRTC.Preview](MedRTC.Preview.md): One replaceable, send-only WebRTC peer for an Opus preview. The caller owns
the peer and receives its ExWebRTC state changes. Capture has its own lifetime.

- [MedRTC.SessionServer](MedRTC.SessionServer.md): OTP `GenServer` owning a live `%MedCore.Session{}` and dispatching emitted
producer facts to registered subscribers.

- [MedRTC.WavCapture](MedRTC.WavCapture.md): Pure-Elixir 16-bit PCM WAV parser and one-input / two-output clinical capture
runner.
- [MedWeb](MedWeb.md): Reusable Phoenix signaling contract (`MedWeb.Signaling`) and shipped browser
`RTCPeerConnection` hook assets for MedEx live sessions.

- [MedWeb.Signaling](MedWeb.Signaling.md): Browser signaling message normalization and reconnect handshake contract for
MedEx live sessions.

