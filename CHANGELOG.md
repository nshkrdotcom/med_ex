# Changelog

## 0.4.0 - 2026-11-26

### Breaking changes

- Make StreamWriter, the immutable journal and verified indexes the sole waveform
  recording path; remove the capture/WAV evidence API, browser assets and media
  provider facades.
- Introduce typed Receipt, RecordingLimits and recovered-prefix contracts,
  explicit owner/fence operations, revision-2 acquisition control and bounded
  per-operation frame/byte credit.
- Separate read-only recovery from authorized terminal-index reconciliation;
  verify bounded segment bytes and derive playback WAV headers from descriptors.
- Require exclusive host root ownership and preserve unknown durable outcomes.
- Build only the base SDK through Weld; the two providers are direct Mix packages.

### Verification and documentation

- Add receipt, capacity, lifecycle, replay, resource-transfer and credit tests.
- Rewrite technical, host, durability and source/release guides for revision 2.
- Native Elixir, detached artifact and service qualification remain mandatory
  before release; this entry does not assert that those gates have passed.

## 0.3.1 — 2026-11-26

- Classify foreign receipt identities before counter rollback and validate handoff context.
- Share durable-prefix and receipt progression checks across the writer and host consumers without changing the wire format.
- Retry the alternate Opus mirror after checksum failure, terminate the Linux codec on supervisor death, and run provider decode tests against the pinned static library.
- Retire a stalled browser preview after one second, notify the subscriber, and allow reconnection while PCM recording continues. The Opus port supervisor reaps stalled codec children on shutdown.
- Harden optional Opus builds against whitespace in build paths and invalid cached downloads. Consumer qualification now decodes a tone from the built encoder and checks its sample count and energy.

## 0.3.0 — 2026-11-25

- Add durability, ordering, and public-surface compatibility guides (`guides/durability_and_guarantees.md`, `guides/stability_and_compatibility.md`) and a standalone CLI reference host (`tools/cli_recorder.exs`).
- Add storage crash-recovery, real provider lifecycle, host `DynamicSupervisor`, and wire/canonical-JSON checks; remove fake-only provider assertions.
- Share one ExDoc Mermaid hook (`build_support/docs_hook.html`) across root and projected builds, rendering diagrams on `exdoc:loaded` in-site navigation and matching light/dark themes.
- Align optional providers (`med_ex_opus 0.2.0` Port-isolated C `libopus` encoder and `med_ex_rtc 0.2.0`) on `med_ex ~> 0.3.0` and Weld `0.19.0`.
- Correct manual checkpoint configuration in the CLI and host/storage fixtures, reject invalid CLI frame counts before writing, and document synchronous commit boundaries and periodic owner-loss behavior accurately.
- Qualify native source and executable bytes when reusing consumer evidence, require all Opus build inputs in Hex archives, and run the CLI host against each selected external SDK transport.
- Refresh release-preparation projections through Weld's current-input cache checks, then seed their archives with source-revision and portable-content checks; an explicit Weld invoker supports prepublication bootstrap without stale same-version base archives.

## 0.2.1 — 2026-11-25

- Verify descriptor identity before opening a stream writer.
- Support `checkpoint_ms: :manual` in `MedEx.StreamWriter` so fenced hosts own every batch flush and owner loss never flushes volatile frames outside the host fence.
- Decode typed segment references and preserve status scalar types in canonical metadata. The earlier generic status mapping could collapse integers and unknown values into strings.
- Align provider packaging verification with independent provider releases.

## 0.2.0 — 2026-11-24

The base SDK covers stream recording and browser WAV capture. Hosts that use
live Opus preview or WebRTC peer negotiation also install the corresponding
provider packages. See the [host integration guide](guides/host_integration.md)
for provider configuration.

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
