# MedEx RTC

MedEx RTC provides `MedEx.RTC.Provider` for send-only WebRTC preview and Opus
RTP packets. It uses ExWebRTC and ExRTP. A host can use it directly or configure
it for the base SDK's preview facade before opening a peer.

```elixir
config :med_ex, :rtc_provider, MedEx.RTC.Provider
```

The package requires Elixir `~> 1.20` and the MedEx base package `~> 0.2.0`.
Install C build tools, pkg-config and OpenSSL development headers for the
ExWebRTC DTLS and SRTP dependencies.

MedEx 0.2.0 is unreleased. For the checkout, choose the base and this package in
the host's Mix dependencies. Use the [source development guide][sources] for
the exact declarations and [host integration guide][integration] for
configuration and process isolation.

[sources]: https://github.com/nshkrdotcom/med_ex/blob/main/guides/source_development.md
[integration]: https://github.com/nshkrdotcom/med_ex/blob/main/guides/host_integration.md
