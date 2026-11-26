<p align="center">
  <img src="assets/med_ex_opus.svg" alt="MedEx Opus logo" width="200" />
</p>

<h1 align="center">MedEx Opus</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex/tree/main/extensions/med_ex_opus"><img src="https://img.shields.io/badge/GitHub-med__ex__opus-345366" alt="GitHub source" /></a>
  <a href="https://github.com/nshkrdotcom/med_ex/blob/main/extensions/med_ex_opus/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

MedEx Opus provides `MedEx.Opus.Provider`, an encoder for
48 kHz mono PCM16LE preview frames. Each provider runs its own libopus encoder
OS process (a Port, no NIF), so a native fault cannot take down the VM. A host can use the provider directly or
configure it for the base SDK's browser capture facade.

```elixir
config :med_ex, :preview_provider, MedEx.Opus.Provider
```

Use `{:med_ex_opus, "~> 0.2.0"}`.

The package requires Elixir `~> 1.20` and the MedEx base package `~> 0.2.0`.
The package pins the Xiph libopus 1.5.2 release tarball (`c_src/vendor/SHA256SUMS`),
fetches and caches it on first build (or reads `MED_EX_OPUS_TARBALL` for offline
builds), verifies its SHA-256, and compiles a static `libopus.a` with
`elixir_make`. You need `cc`, `make`, `tar`, `sh`, and `curl` (unless using
`MED_EX_OPUS_TARBALL`). No system libopus is needed.

## Encoding lifecycle

For direct use, call `MedEx.Opus.Provider.start_link(owner: self())` from the
process that will offer frames. Call `offer(pid, operation, sample_index, pcm)`
with one 20 ms frame (960 samples, 1,920 bytes) and a nonnegative sample index
on the 48 kHz clock. The provider accepts one frame at a time. An `:ok` reply
means the frame was accepted. The owner receives
`{:med_ex_encoded, operation, sample_index, opus}` when encoding finishes.
`{:error, :busy}` means the encoder is starting or already has a frame in
flight. Call `stop(pid)` when preview ends.

This provider encodes audio for preview. For browser delivery, pair it with a
WebRTC transport such as `med_ex_rtc`. Use MedEx capture or stream recording
for the authoritative PCM.

When using a checkout, choose compatible base and provider sources in the
host's Mix dependencies. Use the [source development guide][sources] for
the exact declarations and [host integration guide][integration] for
configuration and process isolation.

[sources]: https://github.com/nshkrdotcom/med_ex/blob/main/guides/source_development.md
[integration]: https://github.com/nshkrdotcom/med_ex/blob/main/guides/host_integration.md
