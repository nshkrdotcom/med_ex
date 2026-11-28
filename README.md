<p align="center">
  <img src="assets/med_ex.svg" alt="MedEx logo" width="200" />
</p>

# MedEx

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex"><img src="https://img.shields.io/badge/GitHub-nshkrdotcom%2Fmed__ex-345366" alt="GitHub repository" /></a>
  <a href="https://github.com/nshkrdotcom/med_ex/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

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

The SDK root remains the real combined `med_ex` application. Its ordinary
matrix is `.`, `extensions/med_ex_opus`, and `extensions/med_ex_rtc`. Quality
also compiles/tests `core/med_core`, `core/med_capture` and `tools/maintainer`
independently, then checks compiled ownership and public API boundaries.
`mix test core/med_capture/test/stream_writer_test.exs:42` targets only the SDK
root; it never forwards that path into either provider. Blitz is source-only
development tooling, excluded from the Weld package's dependencies and files.

## Root command contract

Both repositories expose the following source-development commands. They use
released Blitz 0.5.0 with advisory CPU and memory admission based on the
available host resources. No fixed project-worker cap or scheduler override
is imposed by the workspace runner.

| Command | Default behavior |
|---|---|
| `mix setup` | Fetch genuine root tooling first, then each real project's dev/test/prod dependencies; no upgrade-all. |
| `mix test` | Run all ordinary application suites once, with test compilation and warnings as errors. |
| `mix credo` | Strict Credo in every real application, with exact nonempty source-inventory comparison. |
| `mix dialyzer` | Analyze each real application's nonempty own BEAM inventory using its existing PLT context. |
| `mix quality` | Format, warning-free dev/test compile, ordinary tests, strict Credo, Dialyzer and docs; include private boundary/root tooling checks. |
| `mix docs` | Build root overview and application documentation with warnings as errors. |

Use `mix setup --locked` only after real locks are resolved; it adds
`deps.get --check-locked`. `mix quality --release` adds warning-free production
compilation. `mix quality --project PATH` repeats only an affected project;
`mix test --project PATH -- test/file_test.exs:42 --seed 0 --max-cases 2` forwards
native test arguments to that project. Native leaf commands remain available
from the leaf directory. Quality/setup reject stray arguments. Root Credo is
always strict; use a native leaf task for deliberately focused lint.

Each project owns its dependency, build, lock and PLT paths. Unset inherited
`MIX_EXS`, `MIX_BUILD_PATH`, `MIX_BUILD_ROOT` and `MIX_DEPS_PATH`.
The root runner invokes native tasks without recursive aliases; startup tests
exercise fetched-but-uncompiled dependencies and real Blitz failure propagation.
A missing expected suite, empty BEAM set or incomplete Credo inventory fails.
Cold PLTs can be slow; valid PLTs are not forcibly rebuilt. Root commands do not
start PostgreSQL, HAPI, TURN, browsers, physical ENOSPC or long capture runs.

The implementation environment lacked Elixir/Mix. The command contract and new
Elixir regressions require real workstation compilation and execution before
release; no source documentation asserts an unobserved passing gate.

- [Technical contract](guides/technical_contract.md)
- [Stream recording](guides/stream_recording.md)
- [Durability](guides/durability_and_guarantees.md)
- [Host integration](guides/host_integration.md)
- [Source and package development](guides/source_development.md)
- [Release gates](guides/releasing.md)
- [Architecture](guides/architecture_and_roadmap.md)

See [CHANGELOG.md](CHANGELOG.md).

**License:** [MIT](LICENSE).
