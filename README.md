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

MedEx is an Elixir SDK for recording clinical audio and streaming an independent
live WebRTC Opus preview. It accepts indexed mono 48 kHz signed PCM16LE audio,
writes an immutable content-addressed WAV artifact, and encodes live Opus for a
replaceable WebRTC listener. The host application owns authorization, signaling,
and clinical review.

## Installation

The source tree targets 0.2.0. For a released 0.2.x package, declare the dependency in `mix.exs`.

```elixir
def deps do
  [
    {:med_ex, "~> 0.2.0"}
  ]
end
```

### Prerequisites

- Elixir `~> 1.20` (tested on Elixir `1.20.5` / OTP `29.1.2`).
- On Ubuntu 26.04, native WebRTC dependencies (`ex_dtls`, `ex_libsrtp`) require a
  C compiler, `make`, `pkg-config`, and OpenSSL development headers
  (`build-essential pkg-config libssl-dev`).
- Live Opus encoding uses `membrane_opus_plugin`, which downloads precompiled
  `libopus` binaries on supported Linux/macOS targets and falls back to system
  `libopus-dev` (`pkg-config`) when building from source.

## Quick example

```elixir
# Start a capture under your host DynamicSupervisor (owner is the producer PID)
{:ok, capture} =
  DynamicSupervisor.start_child(
    MyApp.Captures,
    {MedEx.Capture, owner: self(), acquisition_id: "acq-1", artifact_dir: "/var/lib/myapp/wavs"}
  )

# Push contiguous 20 ms chunks (960 mono samples = 1,920 PCM16LE bytes at 48 kHz)
:ok = MedEx.Capture.push(capture, 0, pcm_chunk_0)
:ok = MedEx.Capture.push(capture, 960, pcm_chunk_1)

# Finalize to an immutable "<file_sha256>.wav" file and %MedEx.Evidence{}
{:ok, %MedEx.Evidence{artifact_key: key, file_sha256: sha, sample_count: 1920}} =
  MedEx.Capture.finish(capture)
```

## Capture and preview in 0.2.0

Only the configured producer PID can push samples or finish the recording.
The host can reserve an acquisition ID and directory before opening the microphone
and recover a finalized file under that ID. One listener at a time receives Opus.
Replacing it sends the previous subscriber `{:med_ex_preview_replaced, capture}`.

The browser's `startPCM` takes an optional fifth argument with `deviceId` and
`onSource`. It reports the diagnostic track's actual settings before recording,
so the host can select a separate conversation microphone. The PCM transport
budget is 250 ms of writer acknowledgement delay plus 50 ms of jitter. The
client reports its peak buffered wire bytes and maximum observed WebSocket
acknowledgement delay. WebRTC preview supports host-provided TURN servers and
relay-only ICE policy.

## Guides

- [Host integration](guides/host_integration.md) — Elixir capture/preview
  supervision, Phoenix signaling channel, binary PCM WebSocket contract, and
  browser hook / AudioWorklet setup.
- [Architecture and roadmap](guides/architecture_and_roadmap.md) — Capture vs.
  preview failure domains, shipped vs. planned capabilities, and future
  integrations.
- [Source development](guides/source_development.md) — Working in the source
  monorepo checkout and preparing Weld release bundles.

## License

Released under the MIT License.
