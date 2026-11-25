<p align="center">
  <img src="assets/med_ex_rtc.svg" alt="MedEx RTC logo" width="200" />
</p>

<h1 align="center">MedEx RTC</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex/tree/main/extensions/med_ex_rtc"><img src="https://img.shields.io/badge/GitHub-med__ex__rtc-345366" alt="GitHub source" /></a>
  <a href="https://github.com/nshkrdotcom/med_ex/blob/main/extensions/med_ex_rtc/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

MedEx RTC provides `MedEx.RTC.Provider` for send-only WebRTC preview and Opus
RTP packets. It uses ExWebRTC and ExRTP. A host can use it directly or configure
it for the base SDK's preview facade before opening a peer.

```elixir
config :med_ex, :rtc_provider, MedEx.RTC.Provider
```

Use `{:med_ex_rtc, "~> 0.1.0"}` once the package is available on Hex.

The package requires Elixir `~> 1.20` and the MedEx base package `~> 0.2.0`.
Install C build tools, pkg-config and OpenSSL development headers for the
ExWebRTC DTLS and SRTP dependencies.

When using a checkout, choose compatible base and provider sources in the
host's Mix dependencies. Use the [source development guide][sources] for
the exact declarations and [host integration guide][integration] for
configuration and process isolation.

[sources]: https://github.com/nshkrdotcom/med_ex/blob/main/guides/source_development.md
[integration]: https://github.com/nshkrdotcom/med_ex/blob/main/guides/host_integration.md
