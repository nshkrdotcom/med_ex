<p align="center">
  <img src="assets/med_ex_opus.svg" alt="MedEx Opus logo" width="200" />
</p>

<h1 align="center">MedEx Opus</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex/tree/main/extensions/med_ex_opus"><img src="https://img.shields.io/badge/GitHub-med__ex__opus-345366" alt="GitHub source" /></a>
  <a href="https://github.com/nshkrdotcom/med_ex/blob/main/extensions/med_ex_opus/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

MedEx Opus provides `MedEx.Opus.Provider`, an encoder for
48 kHz mono PCM16LE preview frames. Each provider opens an Erlang Port to a
native process that supervises one libopus codec child. Closing the port lets the supervisor kill and reap the
child even if encoding has stalled. A host can use the provider directly or
configure it for the base SDK's browser capture facade.

```elixir
config :med_ex, :preview_provider, MedEx.Opus.Provider
```

Use `{:med_ex_opus, "~> 0.2.0"}`.

The package requires Elixir `~> 1.20` and the MedEx base package `~> 0.3.0`.
### Build toolchain and platform support

The package pins the Xiph `libopus` 1.5.2 release tarball (`c_src/vendor/SHA256SUMS`),
fetches and caches it under `${XDG_CACHE_HOME:-~/.cache}/med_ex_opus/` on first
build (or reads `MED_EX_OPUS_TARBALL=/path/to/opus-1.5.2.tar.gz` for offline
builds), verifies its SHA-256 before extraction, and compiles a static
`libopus.a` linked into `priv/opus_encoder` via `elixir_make`.

- **Assumed toolchain:** POSIX `cc` (C11), GNU `make`, `tar`, `sh`, and `curl`
  (when not using `MED_EX_OPUS_TARBALL`), plus `sha256sum` or `shasum`.
  No system `libopus-dev` or
  `pkg-config` is needed.
- **Platform qualification:** Natively tested on Ubuntu Linux (`x86_64`, `ext4`).
  macOS and other POSIX hosts use the same standard autotools + C11 build flow
  but have not yet been natively qualified; Windows is unsupported.

An explicitly supplied `MED_EX_OPUS_TARBALL` must be an absolute path to an
existing file, so its meaning is the same from every consumer and provider
working directory. An unset or empty value uses the normal download cache. A missing file
fails without downloading or creating that path. Downloads enter the cache only after
checksum verification, so a later build can retry a failed download. Cached and supplied tarballs
are checked before extraction; a checksum mismatch stops the build. `MIX_APP_PATH`
is supplied by `elixir_make` and must be set for direct `make` or `make clean` calls.
Choose a Mix build directory whose absolute path contains no whitespace.

## Encoding lifecycle

For direct use, call `MedEx.Opus.Provider.start_link(owner: self())` from the
process that will offer frames. Startup waits for the native protocol hello and
fails within five seconds if the child never becomes ready. Call
`offer(pid, operation, sample_index, pcm)`
with one 20 ms frame (960 samples, 1,920 bytes) and a nonnegative sample index
on the 48 kHz clock. The provider accepts one frame at a time. An `:ok` reply
means the frame was accepted. The owner receives
`{:med_ex_encoded, operation, sample_index, opus}` when encoding finishes.
`{:error, :busy}` means the provider already has a frame in flight. Call
`stop(pid)` when preview ends.

## Native regression checks

The provider suite (`mix test`) runs the native protocol checks, including a
20 ms tone decoded with the system libopus shared library. Provider tests and
consumer qualification require Python 3 and that library. Run the protocol
and Makefile cache checks directly with the following commands.

```sh
python3 test/native_protocol_test.py _build/dev/lib/med_ex_opus/priv/opus_encoder
python3 test/build_test.py
```

The build-boundary suite uses a tiny local configure/install fixture and a
controlled download command. It does not qualify the pinned codec build.
Release qualification must also build and test the actual checksum-pinned
libopus tarball offline, run the Elixir provider suites, and decode a real
encoded frame with libopus.

This provider encodes audio for preview. For browser delivery, pair it with a
WebRTC transport such as `med_ex_rtc`. Use MedEx capture or stream recording
for the authoritative PCM.

When using a checkout, choose compatible base and provider sources in the
host's Mix dependencies. Use the [source development guide][sources] for
the exact declarations and [host integration guide][integration] for
configuration and process isolation.

[sources]: https://github.com/nshkrdotcom/med_ex/blob/main/guides/source_development.md
[integration]: https://github.com/nshkrdotcom/med_ex/blob/main/guides/host_integration.md
