<p align="center">
  <img src="assets/med_ex.svg" alt="MedEx logo" width="200" />
</p>

<h1 align="center">MedEx</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex"><img src="https://img.shields.io/badge/GitHub-nshkrdotcom%2Fmed__ex-345366" alt="GitHub repository" /></a>
  <a href="https://github.com/nshkrdotcom/med_ex/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`MedEx` is a generalized, composable Elixir SDK for medical-device waveform, sparse-measurement, and technical-status acquisition.

Medical-device software needs faithful source bytes, explicit sample and epoch coordinates, honest representation of missing data and clock uncertainty, durable replay across intermittent networks, and clear separation between authoritative capture and disposable live monitoring. `MedEx` provides pure functional contracts and bounded local recording primitives so Elixir clinical servers, device gateways, and standalone handheld clients share one verifiable evidence model—while leaving authentication, patient/encounter identity, OTP supervision, clinical review, and EHR/FHIR export in the host application.

## Scope And Capabilities

- **Pure functional contracts (`core/med_core`):**
  - Immutable regular-waveform descriptors (`MedEx.StreamSpec`) with `:s16le`, `:s24le`, and `:s32le` interleaved encodings, rational sample rates, explicit channel calibration (or `:unknown`), clock domains, and `:observed` / `:claimed` processing provenance.
  - Host-admitted waveform frames (`MedEx.SampleFrame`) with transport-independent SHA-256 semantic identity (`MedEx.FrameFingerprint`).
  - Sparse exact-decimal measurements (`MedEx.MeasurementEvent` with `{:value, mantissa, exponent, unit}` or `{:missing, reason}` and raw payload provenance) and technical observations (`MedEx.StatusEvent`).
  - Explicit sample-range or event-scoped qualifiers (`MedEx.IntegritySpan` for `:source_gap`, `:clock_unavailable`, `:configuration_unknown`, `:device_status_invalid`, `:source_processing_unverified`, and `:duplicate_conflict`).
  - Canonical `MEX1` binary waveform framing (`MedEx.Wire.FrameV1`), bounded `medex.device.v1` JSON control envelopes (`MedEx.Wire.Control`), and deterministic `MEJ1` JSON serialization (`MedEx.Serialization`, `MedEx.CanonicalJSON`).
  - Affine rational polytope clock-bound estimation (`MedEx.ClockAlign`) and persist-before-dispatch device command state transitions with explicit `:outcome_unknown` tracking (`MedEx.ControlInterlock`).
- **Authoritative capture, durable acknowledgement, and POSIX recovery (`core/med_capture`):**
  - Per-stream fenced `MedEx.StreamWriter` backed by content-addressed `.pcm` chunks and a checksummed, hash-chained `stream.mejournal` (`MedEx.Storage.File`).
  - Receipts that separate volatile `accepted_*` positions from fsynced `durable_*` positions so upstream spools never delete unacknowledged data.
  - Deterministic replay reconciliation, duplicate-conflict quarantine, explicit `:source_gap` commits, crash recovery (`MedEx.Storage.File.recover/2`), and frozen predecessor lineage import across writer replacements.
- **Browser WAV compatibility and opt-in media extensions:**
  - Preserves continuous 48 kHz mono PCM16LE browser capture (`MedEx.Capture`, `MedEx.Evidence`, `MedEx.Wav`) and packaged JavaScript AudioWorklet / LiveView helpers (`MedEx.Web`).
  - Isolates native Opus encoding (`:med_ex_opus`) and WebRTC peer transport (`:med_ex_rtc`) into optional extension packages behind `MedEx.PreviewProvider` and `MedEx.RTCProvider`, so headless servers and edge clients compile with zero C/NIF or media dependencies.

## Canonical Application Composition

The canonical Mix application is `:med_ex` (`Elixir ~> 1.20`). It compiles `core/med_core/lib` and `core/med_capture/lib` into a single OTP application with zero runtime Hex dependencies (`extra_applications: [:logger, :crypto]`) and **starts no global supervision tree or background processes**. Hosts start `MedEx.StreamWriter` or `MedEx.Capture` directly under their own supervisors.

The two private component projects compile and test independently. The root Mix
project and the Weld base artifact derive their component lists from the same
declaration. Consumers choose `:med_ex` and add the independently installable
`:med_ex_opus` or `:med_ex_rtc` package when the host uses that provider.

## Installation And Dependency Consumption

The `0.3.x` SDK implements contract revision 1 with host-fenced manual checkpoints, durability/compatibility guides, and separate media providers (`med_ex_opus ~> 0.2.0`, `med_ex_rtc ~> 0.2.0`). The `0.1.0` package has the original
browser WAV capture and preview API. [Hex package history](https://hex.pm/packages/med_ex)

Consumers use standard Mix dependencies and never need `Weld` installed:

```elixir
# Hex (headless base SDK)
{:med_ex, "~> 0.3.0"}

# Local source checkout (headless base SDK)
{:med_ex, "~> 0.3.0", path: "../med_ex"}

# Pinned Git commit on main (headless base SDK)
{:med_ex, "~> 0.3.0", github: "nshkrdotcom/med_ex", ref: "<commit_sha>"}

# Optional live media extensions (from checkout or Git subdir; use override: true on :med_ex so extensions converge on your chosen base)
{:med_ex, "~> 0.3.0", github: "nshkrdotcom/med_ex", ref: "<commit_sha>", override: true},
{:med_ex_opus, "~> 0.2.0", github: "nshkrdotcom/med_ex", ref: "<commit_sha>", subdir: "extensions/med_ex_opus"},
{:med_ex_rtc, "~> 0.2.0", github: "nshkrdotcom/med_ex", ref: "<commit_sha>", subdir: "extensions/med_ex_rtc"}

# Previously published 0.1.0 legacy browser WAV/preview package on Hex
{:med_ex, "~> 0.1.0"}
```

The optional `tools/maintainer` project generates graph-composed base and
standalone extension views with Weld. The three artifacts are `med_ex`,
`med_ex_opus`, and `med_ex_rtc`. Consume each live, full or prepared project
with an ordinary Mix path dependency, or use an exact Git revision of a tracked
snapshot. [Consumption, Extensions, and Verification](guides/source_development.md)

## Quick Example: Authoritative Stream Recording

```elixir
alias MedEx.{SampleFrame, Serialization, StreamSpec, StreamWriter}

base_spec = %StreamSpec{
  acquisition_id: "acq-01",
  source_ref: "dev-gateway-01",
  boot_id: "boot-9f2a",
  stream_id: "ecg-lead-ii",
  source_epoch: 0,
  descriptor_ref: String.duplicate("0", 64),
  modality: "cardiac:ecg",
  encoding: :s16le,
  channels: [
    %{
      id: "lead_ii",
      label: "Lead_II",
      unit: "uV",
      calibration: %{zero: 0, scale_num: 5, scale_den: 2, reference: "factory_cal_v1"}
    }
  ],
  sample_rate: {500, 1},
  capabilities: %{
    encodings: [:s16le],
    max_frame_samples: 250,
    max_payload_bytes: 1_000,
    replay: :durable_spool,
    commands: []
  }
}

spec = %{base_spec | descriptor_ref: Serialization.descriptor_ref(base_spec)}

{:ok, writer} =
  StreamWriter.start_link(
    owner: self(),
    stream: spec,
    artifact_dir: "/var/lib/my_host/acquisitions/acq-01/ecg-fence-1",
    fence: "fence-1"
  )

frame = %SampleFrame{
  stream_id: spec.stream_id,
  source_epoch: spec.source_epoch,
  descriptor_ref: spec.descriptor_ref,
  sequence: 0,
  first_sample: 0,
  sample_count: 100,
  config_epoch: 0,
  payload: :binary.copy(<<0, 0>>, 100)
}

{:ok, _accepted_receipt} = StreamWriter.push(writer, "fence-1", frame)
{:ok, durable_receipt} = StreamWriter.checkpoint(writer)
{:ok, sealed_index} = StreamWriter.finish(writer)
IO.inspect({durable_receipt.durable_sequence, durable_receipt.durable_sample, sealed_index})
```

Only `durable_receipt.durable_sequence` / `durable_sample` authorize upstream spool truncation; `sealed_index` (`%MedEx.StreamIndex{}`) records verified `.pcm` segment digests, any explicit `:source_gap` or qualifier spans, and the journal digest.

## Optional Opus And WebRTC Providers

`:med_ex_opus` (`MedEx.Opus.Provider`, backed by a libopus encoder process) and `:med_ex_rtc` (`MedEx.RTC.Provider`, backed by ExWebRTC / ExRTP) are independent OTP applications:

- Use `:med_ex_opus` alone to encode 20 ms 48 kHz mono PCM16LE frames under single-frame backpressure (`MedEx.PreviewProvider`).
- Use `:med_ex_rtc` alone to negotiate send-only WebRTC peers and transmit pre-encoded Opus RTP packets (`MedEx.RTCProvider`).
- Configure both in-VM for legacy `MedEx.Capture` / `MedEx.Preview` browser sessions:

```elixir
config :med_ex,
  preview_provider: MedEx.Opus.Provider,
  rtc_provider: MedEx.RTC.Provider
```

`:med_ex_opus` isolates its C11 `libopus` encoder in a separate OS process over a `Port` (no NIF), while `:med_ex_rtc` loads native DTLS/SRTP NIFs via ExWebRTC. Strict deployments can keep the authoritative `:med_ex` recording host headless and run `:med_ex_opus` + `:med_ex_rtc` inside a separate sidecar OS process.

## Local Verification

With Elixir `~> 1.20` (and Node.js for browser worklet unit tests):

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs --warnings-as-errors
node --test test/*.mjs
./build_support/check_architecture.sh
```

## Guides

- [Architecture and Composition](guides/architecture_and_roadmap.md) — Canonical `:med_ex` source ownership, pure-vs-effectful boundaries, OTP supervision, and media fault isolation.
- [Streams, Storage, Clock, and Control](guides/stream_recording.md) — `StreamSpec`, `MEX1`/`MEJ1` framing, sparse measurements, `StreamWriter`, POSIX crash recovery, predecessor lineage, `ClockAlign`, and `ControlInterlock`.
- [Host Integration and Browser Compatibility](guides/host_integration.md) — Practical host gateway patterns alongside browser `MedEx.Capture`, `MedEx.Preview`, and `MedEx.Web` JavaScript integration.
- [Consumption, Extensions, and Verification](guides/source_development.md) — Direct, Git, projection, and Hex consumption, extension development, and package verification.
- [Medical-Device Product Horizon](guides/product_horizon.md) — Implemented capabilities versus physical-device characterization, clinical validation, and future device families.

## License

Released under the [MIT License](LICENSE).
