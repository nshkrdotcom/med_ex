# MedEx Opus

MedEx Opus provides `MedEx.Opus.Provider`, a Membrane-backed encoder for
48 kHz mono PCM16LE preview frames. A host can use the provider directly or
configure it for the base SDK's browser capture facade.

```elixir
config :med_ex, :preview_provider, MedEx.Opus.Provider
```

The package requires Elixir `~> 1.20` and the MedEx base package `~> 0.2.0`.
Install a C compiler and native build tools for the Membrane Opus plugin.
On supported Linux and macOS targets the plugin can use precompiled libopus.
For a source build, install the libopus development headers and libraries.

MedEx 0.2.0 is unreleased. For the checkout, choose the base and this package in
the host's Mix dependencies. Use the [source development guide][sources] for
the exact declarations and [host integration guide][integration] for
configuration and process isolation.

[sources]: https://github.com/nshkrdotcom/med_ex/blob/main/guides/source_development.md
[integration]: https://github.com/nshkrdotcom/med_ex/blob/main/guides/host_integration.md
