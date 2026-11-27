# MedEx

MedEx 0.4.0 is an Elixir SDK for source-preserving waveform and measurement
acquisition. It provides pure stream/frame/event contracts, a single fenced
StreamWriter and immutable journal/index verification. The host supplies
identity, authorization, exclusive root ownership and clinical interpretation.

## Packages

| Package | Version | Build | Runtime purpose |
|---|---|---|---|
| med_ex | 0.4.0 | Weld package projection | Technical contracts and durable streams |
| med_ex_opus | 0.3.0 | Direct Mix | One owner-bound encoder and native Port |
| med_ex_rtc | 0.3.0 | Direct Mix | Concrete owner-bound WebRTC/RTP peer |

The optional providers have no dependency on this base package or on each other.
The base starts no recording or media service and contains no browser assets.

```elixir
def deps, do: [{:med_ex, "~> 0.4.0"}]
```

Use Elixir ~> 1.20; the checked-in toolchain pins Elixir 1.20.5 and OTP 29.1.2.
See `.tool-versions` for exact development tooling. Protocol/API revision is 2;
the current control schema is `medex.acquisition.v2`. MEX1 and MEJ1 bytes retain
their defined encoding. Unsupported namespace/protocol identities are refused.

## Recording

1. Establish exclusive OS ownership of a trusted artifact root. Bind source
   identity and reserve a unique fence before opening a writable attempt.
2. Validate a `MedEx.StreamSpec`; start `MedEx.StreamWriter` with explicit owner,
   fence, artifact directory, root owner and recording limits.
3. Push frames or explicit gaps under that fence. Accepted bytes may be volatile.
4. Checkpoint and validate a fully durable `MedEx.Receipt` before persistence or
   acknowledgment. Clients retain source until their durable ACK is persisted.
5. Drain the exact final source cursor, checkpoint, then finish. Verify the actual
   terminal index and receipt. Recover read-only; reconcile a missing terminal
   index only after authorized positive effect quiescence.

`tools/cli_recorder.exs` is a complete standalone host using an OS `flock`,
explicit fenced operations and verified recovery. Copy it into a fresh Mix
consumer to test the installed SDK independently:

```sh
mix run tools/cli_recorder.exs /service-owned/private-recording 4
```

No automatic data reset or historical reader exists. Use fresh revision-2
artifact namespaces; preserve existing evidence in verified offline archives.
Synthetic/reference tests establish software behavior, not physical calibration
or clinical readiness.

## Development and qualification

The root Mix project is for source development. `core/med_core` and
`core/med_capture` are private testing boundaries; the one published SDK is the
Weld projection declared in `build_support/composition.exs` and `weld.exs`.
Run `mix format --check-formatted`, warning-free compilation, tests, Credo,
Dialyzer and ExDoc. Build and test each optional package from its own directory.
Native, filesystem, detached consumer and coordinated release gates remain
separate requirements; a source or compile check alone is not qualification.

- [Technical contract](guides/technical_contract.md)
- [Stream recording](guides/stream_recording.md)
- [Durability](guides/durability_and_guarantees.md)
- [Host integration](guides/host_integration.md)
- [Source and package development](guides/source_development.md)
- [Release gates](guides/releasing.md)
- [Architecture](guides/architecture_and_roadmap.md)

Released under the MIT License. See [CHANGELOG.md](CHANGELOG.md).
