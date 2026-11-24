# MedEx

MedEx is an Elixir SDK for source-preserving waveform acquisition. The canonical
Mix application is `:med_ex`. It contains pure descriptor, wire, clock and
control contracts, a per-stream journal-backed recorder, and the existing
continuous mono WAV capture interface. Hosts own identity, admission, lifecycle
and review. The application starts no collection service.

This source tree implements contract revision 1 at the existing package version.
The previously published Hex 0.2.0 is the legacy capture/preview package. Check
`MedEx.Contract.api_revision/0` when consuming unreleased contracts. A local
checkout is usable directly:

```elixir
{:med_ex, "~> 0.2.0", path: "../med_ex"}
```

Run `mix deps.get && mix test` with Elixir ~> 1.20. A headless consumer has no
native codec or RTC dependencies. For legacy WebRTC preview, add both extension
projects and configure their providers explicitly:

```elixir
config :med_ex,
  preview_provider: MedEx.Opus.Provider,
  rtc_provider: MedEx.RTC.Provider
```

The Opus extension also encodes on its own. The RTC extension can send compatible
Opus packets supplied by another source. An in-process media provider shares the
host VM's native failure domain.

## Recording guides

- [Stream API and POSIX recovery](guides/stream_recording.md)
- [Legacy capture, preview and browser assets](guides/host_integration.md)
- [Source projects, checks and optional dependencies](guides/source_development.md)
- [Product horizon and candidate use cases](guides/product_horizon.md)
- [Component ownership](guides/architecture_and_roadmap.md)

Released under the MIT license.
