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

MedEx is an Elixir SDK for recording clinical audio and sending an independent
WebRTC preview. The SDK accepts indexed mono PCM16 at 48 kHz, writes an immutable WAV,
and encodes live Opus for a WebRTC listener. The host owns access, signaling, and clinical review.

## Install and use

For the prepared candidate, use the generated Mix project from the release
bundle as a local path dependency. The intended Hex dependency after
publication is:

```elixir
{:med_ex, "~> 0.1.0"}
```

Use Elixir 1.20. On Ubuntu, the native WebRTC dependencies require a C
toolchain, pkg-config, and OpenSSL development headers.

Start with [Host integration](guides/host_integration.md) to set up a peer,
serve the browser hook, and record the input. Read
[Architecture and roadmap](guides/architecture_and_roadmap.md) for the capture
and preview boundaries and future integrations.

## Contribute

The source checkout contains the separate Mix projects and release tooling.
See [Source development](guides/source_development.md).
