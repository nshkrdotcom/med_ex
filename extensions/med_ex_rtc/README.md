# MedEx RTC

`med_ex_rtc` is an independent concrete send-only Opus/WebRTC capability. It
requires Elixir `~> 1.20`, ExWebRTC `~> 0.18.0` and ExRTP `~> 0.4`; it has no
dependency on `med_ex` or `med_ex_opus`. Add `{:med_ex_rtc, "~> 0.3.0"}` to the
host and build directly from `extensions/med_ex_rtc`.

## Owner-bound peer

```elixir
options = [owner: self(), ice_servers: [], ice_transport_policy: :all]
:ok = MedEx.RTC.Provider.validate_options(options)
{:ok, peer, answer_sdp} = MedEx.RTC.Provider.answer(offer_sdp, options)
peer_ref = MedEx.RTC.Provider.peer_ref(peer)
receive do
  {:med_ex_rtc, ^peer_ref, :connected} -> :ok
end
deadline = System.monotonic_time(:millisecond) + 1_000
:ok = MedEx.RTC.Provider.send_opus(peer, opus, emitted_sequence, elapsed_media_tick, deadline)
:ok = MedEx.RTC.Provider.close(peer)
```

The host supplies signaling, authentication, authorization, peer-session policy
and encoded Opus packets. `answer/2` requires one receive-only audio media
section advertising Opus at 48 kHz. It returns an opaque peer handle and fully
gathered send-only answer. The handle is not a public ExWebRTC PID or track ID;
`peer_ref/1` is the supported notification identity. Notifications are
`{:med_ex_rtc, peer_ref, state}`. Only the explicit owner may send or close.
The startup caller may differ from the owner; loss of either retires the peer.

`send_opus/5` accepts one 1–1,275-byte Opus packet, an unsigned 64-bit logical
emitted-packet sequence, an unsigned 64-bit elapsed media tick and a local
monotonic deadline in milliseconds. The media clock is 48 kHz. Dropping a
preview frame advances elapsed media time but does not consume an emitted
sequence number. The provider alone wraps sequence and timestamp to the RTP
16-bit and 32-bit fields. It performs no source-clock conversion, packet
retention, replay or waveform storage.

The deadline is checked in the caller and again at the concrete transport
submission boundary. The ExWebRTC send API is asynchronous; a subsequent
ordered public statistics query confirms packet processing. An unconfirmed
submission returns an unknown outcome and retires the peer. Already submitted
packets cannot be recalled. Deadline expiry, transport failure, disconnect,
owner loss and caller abandonment close the child peer. Hosts treat preview
failure as a drop, never as failure of already committed source evidence.
Negotiation is bounded to ten seconds with an eleven-second outer startup
bound; ICE gathering is bounded to five seconds; sends and close are bounded
to one second or the earlier supplied deadline.

## ICE policy and qualification

`validate_options/1` checks the same bounded owner and ICE policy used by
`answer/2`, without opening a peer. Hosts can call it before activating a
listener. Options are `:owner`, `:ice_servers` and `:ice_transport_policy`.
The server list is bounded to eight entries and eight URLs per entry. Relay
policy requires an explicit TURN URL. Configure TURN credentials in authorized
runtime configuration, and select relay on both peers when qualifying relay
behavior. There is no hard-coded public STUN service or implicit environment
lookup in the provider.

Build tools, pkg-config and OpenSSL headers are needed for the ExWebRTC native
DTLS/SRTP dependencies. ExWebRTC's transitive `ex_dtls`, `ex_libsrtp` and `shmex`
NIFs load into the BEAM running `med_ex_rtc`. The base SDK, Opus Port, Exam and
Handheld intended authoritative dependency closures contain no application-owned
or third-party NIF extensions; OTP itself can use native implementations.
Production `mf_preview` therefore runs in a separate OS BEAM with no clinical
database or raw-record authority. The combined six-package `hex_smoke` example
proves dependency resolution and installation, not safe production co-hosting.

Run `mix test` for actual negotiation, receive-side RTP
payload/sequence/timestamp checks, malformed input, owner/caller lifetimes,
queued deadline expiry and cleanup. Tests supply an independently known Opus
silence packet; they do not install an encoder or base SDK. To include the
relay test, set `MED_EX_RTC_TURN_URL`, `MED_EX_RTC_TURN_USERNAME` and
`MED_EX_RTC_TURN_CREDENTIAL`. Without TURN configuration that separate case is
excluded and remains **NOT RUN**. Browser and deployment NAT/TURN behavior must
also be qualified in the deployment environment. A source/static check does
not establish WebRTC, native DTLS, browser or relay qualification.
