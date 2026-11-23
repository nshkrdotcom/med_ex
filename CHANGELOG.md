# Changelog

## 0.2.0 (unreleased)

- Isolate Opus encoder startup and lifecycle in a disposable preview session;
  keep capture writes and finish independent of preview startup or failure.
- Share pure frame admission, canonical WAV header validation, and preview clock
  rules in the existing SDK project.
- Consolidate browser assets and tests into `core/med_rtc`, preserving the
  `MedEx.Web` API and packaged asset paths; remove `core/med_web`.
- Authorize capture writes and finish by producer PID. Notify a displaced preview listener.
- Select a logical diagnostic input and expose actual browser settings before streaming.
- Budget 250 ms of PCM acknowledgement delay plus 50 ms of jitter and report transport measurements.
- Apply host-selected relay policy and ICE servers to browser and server preview.

## 0.1.0

- Record indexed browser PCM as content-addressed WAV evidence.
- Encode live Opus on a bounded preview branch with replaceable WebRTC peers.
- Provide host-configurable ICE, browser capture assets, and standalone integration guides.
