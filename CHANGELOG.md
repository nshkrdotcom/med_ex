# Changelog

## 0.2.0 (unreleased)

- Drive direct Mix compilation and the graph-composed base package from a
  shared component declaration. Generate separate live and full views for
  the base, Opus and RTC packages.
- Use normal versioned Hex dependencies on the base from both media packages.
  Exercise prerelease sources with explicit host dependencies and use a
  private signed registry to verify package resolution.
- Make the public root compile the pure Core and Capture runtime source trees
  directly. Keep the component Mix projects for independent verification.
- Move native encoding and peer negotiation into opt-in Opus and RTC packages.
  Preserve legacy Capture, Evidence, WAV, Preview and browser asset APIs.
- Add revision-1 waveform, sparse measurement and status contracts, MEX1
  framing, canonical MEJ1 metadata and transport-independent frame identity.
- Add bounded per-stream recording, synced immutable chunks, journal receipts,
  explicit gap records, frozen predecessor import and verified index recovery.
- Add rational clock-alignment bounds and technical control reconciliation
  with explicit unknown outcomes.

- Isolate Opus encoder startup and lifecycle in a disposable preview session;
  keep capture writes and finish independent of preview startup or failure.
- Share pure frame admission, canonical WAV header validation, and preview clock
  rules in the existing SDK project.
- Consolidate browser assets and tests into `core/med_capture` and `priv/static/med_web/`,
  preserving the `MedEx.Web` API and packaged asset paths; retire `core/med_web`
  and `core/med_rtc`.
- Authorize capture writes and finish by producer PID. Notify a displaced preview listener.
- Select a logical diagnostic input and expose actual browser settings before streaming.
- Budget 250 ms of PCM acknowledgement delay plus 50 ms of jitter and report transport measurements.
- Apply host-selected relay policy and ICE servers to browser and server preview.

## 0.1.0

- Record indexed browser PCM as content-addressed WAV evidence.
- Encode live Opus on a bounded preview branch with replaceable WebRTC peers.
- Provide host-configurable ICE, browser capture assets, and standalone integration guides.
