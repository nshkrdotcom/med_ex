# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-11-26

### Breaking changes

- Provide one concrete owner-bound opaque RTC handle with peer_ref/1 and a single
  state notification contract. Remove base SDK dependency and global selection.
- Bound signaling and peer lifetime, enforce owner checks and monotonic submission
  deadlines, and validate RTP sequence/tick conversion at the transport boundary.
- Keep independent ExWebRTC/ExRTP operation with externally encoded Opus packets.
- Publish directly from this Mix project; no provider Weld projection.

### Hardening

- Normalize expected startup refusals without OTP argument dumps and preserve
  owner-checked teardown and ICE input validation.
- Update third-party dependency floors (`ex_rtp ~> 0.4.1`, `credo`, `dialyxir`,
  `ex_doc`).

### Tests and documentation

- Update standalone negotiation, ownership, deadline, teardown and wrap tests.
- Document direct and relay-only native receiver qualification requirements.

## [0.2.1] - 2026-11-26

- Qualify the WebRTC provider with the MedEx 0.3.1 release family.

## [0.2.0] - 2026-11-25

- Align base SDK requirement to `med_ex ~> 0.3.0`.

## [0.1.0] - 2026-11-24

- Add the ExWebRTC provider for send-only WebRTC preview and Opus RTP.
- Integrate with MedEx `~> 0.2.0`.

[0.3.0]: https://github.com/nshkrdotcom/med_ex/compare/med_ex_rtc-v0.2.1...med_ex_rtc-v0.3.0
[0.2.1]: https://github.com/nshkrdotcom/med_ex/compare/med_ex_rtc-v0.2.0...med_ex_rtc-v0.2.1
[0.2.0]: https://github.com/nshkrdotcom/med_ex/compare/med_ex_rtc-v0.1.0...med_ex_rtc-v0.2.0
[0.1.0]: https://github.com/nshkrdotcom/med_ex/releases/tag/med_ex_rtc-v0.1.0
