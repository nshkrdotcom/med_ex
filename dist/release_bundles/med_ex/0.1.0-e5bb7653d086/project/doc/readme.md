<p align="center">
  <img src="assets/med_ex.svg" width="200" height="200" alt="MedEx logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex">
    <img alt="GitHub: med_ex" src="https://img.shields.io/badge/GitHub-med_ex-0b0f14?logo=github" />
  </a>
  <a href="https://github.com/nshkrdotcom/med_ex/blob/main/LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# MedEx

`MedEx` is a reusable Elixir SDK poncho for live clinical device sessions, WebRTC transport, and independent recording integrity. It separates what the clinician hears live over WebRTC from what the device records losslessly, so a browser disconnect never corrupts or mislabels a clinical capture.

The repository is a non-umbrella Elixir poncho managed with Blitz (parallel checks) and Weld (single-artifact SDK projection). Downstream apps such as `med_fabric/apps/exam` consume one OTP application (`:med_ex`), never individual internal path dependencies.

---

## What This Owns (and Does Not Own)

**`med_ex` owns:**
- Pure live-session state transitions (`MedCore.Session`) with a four-level identity model (`encounter_ref`, `session_id`, `connection_id`, `acquisition_id`) and separate integrity tracking for `{:preview_stream, stream_id}` vs. `{:recording_artifact, acquisition_id}`.
- OTP runtime and WebRTC/audio transport (`MedRTC.Preview` over ExWebRTC and `MedRTC.WavCapture`).
- Reusable signaling event helpers and the shipped browser WebRTC JavaScript hook (`MedWeb.Signaling`, `priv/static/med_web/session_hook.js`).

**`med_ex` does not own:**
- Durable clinical encounters, clinician observation acceptance, transactional outbox storage, HL7 FHIR delivery, or production Phoenix endpoints/LiveViews/signaling channels. Those live in the companion `med_fabric` workspace (`med_fabric/apps/exam` consumes `:med_ex` one-way).

---

## Package Map

| Package | Path | Included in `:med_ex` SDK? | Implemented Today | Documentation |
| --- | --- | --- | --- | --- |
| **MedCore** | `core/med_core` | Yes | `MedCore.Session`, `MedCore.StreamSpec`, `MedCore.Profile` | [core/med_core/README.md](core/med_core/README.md) |
| **MedRTC** | `core/med_rtc` | Yes | `MedRTC.SessionServer`, `MedRTC.PeerLoopback` (`ExWebRTC`), `MedRTC.WavCapture` | [core/med_rtc/README.md](core/med_rtc/README.md) |
| **MedWeb** | `core/med_web` | Yes | `MedWeb.Signaling`, `priv/static/med_web/session_hook.js` | [core/med_web/README.md](core/med_web/README.md) |

---

## Capture walkthrough

`MedRTC.Preview` negotiates receive-only browser audio and sends Opus RTP. `MedRTC.WavCapture.record/4` paces the CirCor recording, feeds its preview independently, and finalizes the original PCM with a digest. The pure session reducer checks acquisition identity and protects completed captures from conflicting redelivery.

## Commands & Verification

Toolchain pins live in `.tool-versions` (`erlang 29.1.2`, `elixir 1.20.5-otp-29`). Ordinary Elixir, Blitz, and Weld checks run without external services once dependencies are installed.

```bash
# Inner dev loop (parallel across all three child projects via Blitz)
mix deps.get
mix monorepo.deps.get
mix ci
mix monorepo.dialyzer
mix monorepo.docs && mix docs

# Welded :med_ex SDK projection & provenance checks
mix weld.project
mix weld.inspect
mix weld.verify

# Publish verified projection to orphan branch projection/med_ex
mix weld.release.prepare
mix weld.release.track --push

# Optional: download real PhysioNet CirCor 2530_AV.wav (gitignored) & verify PCM SHA-256 via uv
bash fixtures/circor/prepare.sh fixtures/circor
```

## Upstream Ecosystem

- Blitz: https://github.com/nshkrdotcom/blitz
- Weld: https://github.com/nshkrdotcom/weld
- ExWebRTC: https://github.com/elixir-webrtc/ex_webrtc
- LiveExWebRTC: https://github.com/elixir-webrtc/live_ex_webrtc
- ExSCTP: https://github.com/elixir-webrtc/ex_sctp
- Membrane Core: https://github.com/membraneframework/membrane_core
- PhysioNet CirCor DigiScope Phonocardiogram Dataset: https://physionet.org/content/circor-heart-sound/1.0.3/

## License

MIT — see [LICENSE](LICENSE).

## Browser capture architecture

```mermaid
flowchart LR
    WAV["Verified PCM WAV"] --> Capture["Paced capture task"]
    Capture --> Artifact["Finalized WAV + PCM digest"]
    Opus["Opus preview from the same fixture"] --> Preview["Bounded preview worker"]
    Capture -->|"20 ms frame index"| Preview
    Preview --> Peer["Replaceable ExWebRTC peer"]
    Peer --> Browser["Clinician audio track"]
    Browser <-->|"SDP with gathered ICE"| Host["Authorized host signaling channel"]
    Host --> Peer
    Artifact --> Host
```

The host starts `MedRTC.WavCapture.record/4` in an acquisition task. A separate worker supplies best-effort Opus preview frames. The browser's peer can close or rejoin without interrupting the acquisition. The task returns a finalized WAV path, decoded PCM SHA-256, retained frame count, duration and measured continuity. The host owns access to the artifact and starts any review or clinical persistence.

To prepare the real fixture with the shipped lock, install curl and uv and run `./fixtures/circor/prepare.sh /path/to/cache` from the source checkout. For a Welded SDK, run `bash <sdk checkout>/priv/fixtures/prepare.sh /path/to/cache`. uv resolves Python 3.12.14 and the pinned FFmpeg wheel for the host. The script verifies the original WAV before producing its 20 ms Opus preview. The fixture is distributed separately from the SDK and retains the attribution recorded in `priv/fixtures/MANIFEST.json`.

The reusable browser hook is created by `createMedExHook(Socket)` from the packaged `priv/static/med_web/session_hook.js`. The host supplies its Phoenix Socket constructor, a signed token in the hook element, and an encounter topic. The preview owns the browser connection. The host authorizes it and hands the gathered offer to `MedRTC.Preview.answer/1`.

## Native onboarding on Ubuntu 26.04

Install Git, curl, tar, build-essential, pkg-config, and uv. Activate the exact Erlang and Elixir versions in `.tool-versions` with asdf or mise. Run `./onboard.sh --fixture` to verify the toolchain, fetch Mix dependencies, and prepare the verified WAV and its Opus preview. Then run `mix ci` and `mix weld.verify`. Fabric owns the browser integration test.

```mermaid
flowchart LR
  W["Verified fixture WAV"] --> R["Acquisition task"]
  O["Prepared Opus frames"] --> R
  R --> A["Finalized original PCM artifact"]
  R -->|"Best-effort preview frames"| P["Replaceable ExWebRTC peer"]
  P --> B["Clinician browser"]
```

The acquisition task owns the recording deadline and finalized artifact. A bounded preview worker forwards frames independently. A browser peer can be replaced during capture. The Fabric host owns authorization and clinical acceptance.
