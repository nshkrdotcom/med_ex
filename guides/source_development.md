# Consumption, Extensions, and Verification

`MedEx` is an ordinary Mix project at the repository root (`:med_ex`) accompanied by two optional extension packages (`extensions/med_ex_opus` and `extensions/med_ex_rtc`) and an isolated maintainer projection project (`tools/maintainer`). Ordinary consumers and contributors never need `Weld` or `Mix Workspace Ops` installed.

## Consuming `:med_ex` Across Transports

> **Published Hex vs `main`-tree capabilities:** Hex currently carries `med_ex 0.1.0` (initial continuous browser WAV capture and in-tree preview). The `main` branch at `0.2.0` implements contract revision 1 (`MedEx.Contract.api_revision() == 1`), adding generalized waveform/sparse-measurement/status contracts, `StreamWriter` POSIX journaled storage and recovery, `ClockAlign`, `ControlInterlock`, and separate `:med_ex_opus` / `:med_ex_rtc` extension packages.

Downstream Mix projects can depend on `:med_ex` through any standard Mix source:

| Consumption Mode | Mix Dependency Declaration | Notes |
| --- | --- | --- |
| Direct checkout root | `{:med_ex, "~> 0.2.0", path: "../med_ex"}` | Uses the root `mix.exs` directly; zero generated files needed. |
| Git commit on `main` | `{:med_ex, "~> 0.2.0", github: "nshkrdotcom/med_ex", ref: "<sha>"}` | Recommended for reproducible pre-release integration. |
| Weld live projection | `{:med_ex, "~> 0.2.0", path: "../med_ex/.weld/live/med_ex"}` | Symlinked view into the checkout; source edits apply on next compile. |
| Weld full / prepared projection | `{:med_ex, "~> 0.2.0", path: "../med_ex/.weld/full/med_ex/project"}` *(or `.weld/releases/med_ex/<id>/project`)* | Self-contained directory copy; prepared `<id>` paths are immutable across concurrent builds. |
| Tracked projection branch | `{:med_ex, "~> 0.2.0", github: "nshkrdotcom/med_ex", ref: "<projection_sha>"}` | Consumes a snapshot committed on `projection/med_ex`. |
| Published Hex (`0.1.0` legacy) | `{:med_ex, "~> 0.1.0"}` | Legacy browser WAV capture/preview contract only (`MedEx.Contract` absent). |

When migrating an older consumer from `0.1.0` (or the retired `:med_rtc` package) to `0.2.0` source:

1. Replace any `:med_rtc` dependency with `:med_ex`.
2. Add `:med_ex_opus` and `:med_ex_rtc` only in applications that actually encode Opus or negotiate WebRTC peers, and set `config :med_ex, preview_provider: MedEx.Opus.Provider, rtc_provider: MedEx.RTC.Provider`.

## Installing And Developing Optional Extensions

`:med_ex_opus` and `:med_ex_rtc` live under `extensions/med_ex_opus` and `extensions/med_ex_rtc`. Each is an independent OTP application with its own `VERSION`, `LICENSE`, `mix.exs`, and `build_support/sources.exs` so its Hex archive is self-contained.

### In A Host Application

Select a single authoritative `:med_ex` dependency in the host (with `override: true` so both extensions converge on the host's chosen `:med_ex` revision or path):

```elixir
# Local path example:
{:med_ex, "~> 0.2.0", path: "../med_ex", override: true},
{:med_ex_opus, "~> 0.2.0", path: "../med_ex/extensions/med_ex_opus"},
{:med_ex_rtc, "~> 0.2.0", path: "../med_ex/extensions/med_ex_rtc"}

# Git commit example:
{:med_ex, "~> 0.2.0", github: "nshkrdotcom/med_ex", ref: "<med_ex_sha>", override: true},
{:med_ex_opus, "~> 0.2.0", github: "nshkrdotcom/med_ex", ref: "<med_ex_sha>", subdir: "extensions/med_ex_opus"},
{:med_ex_rtc, "~> 0.2.0", github: "nshkrdotcom/med_ex", ref: "<med_ex_sha>", subdir: "extensions/med_ex_rtc"}
```

Native build prerequisites apply **only** when `:med_ex_opus` (`membrane_opus_plugin`) or `:med_ex_rtc` (`ex_webrtc` / `ex_dtls` / `ex_libsrtp`, requiring C compiler, `pkg-config`, and OpenSSL headers) is included.

### Standalone Extension Development (`.mix_sources.json`)

By default, each extension's `mix.exs` pins a verified `:med_ex` GitHub commit so standalone builds are reproducible without sibling-directory assumptions. When working inside an extension directory against a local `:med_ex` checkout or projection, place an untracked `.mix_sources.json` at the `med_ex` checkout root (or beside the extension's `mix.exs` in an unpacked archive):

```json
{"med_ex": {"path": "."}}
```

Paths resolve relative to `.mix_sources.json`. Supported entries are `{"path": "..."}` (checkout, live, full, or prepared projection), `{"github": "org/repo", "ref"|"branch"|"tag": "...", "subdir": "..."}` (or `"git"`), and `{"hex": "med_ex", "repo": "hexpm"}`.

Whenever `.mix_sources.json` selects a non-default source, `BuildSources.resolve/3` isolates `lockfile`, `deps_path`, and `build_path` under `_build/source_contexts/<context_sha256>/`—keyed by project directory, normalized dependencies, full-projection `artifact_id` (when present in `weld.provenance.json`), baseline `mix.lock`, Elixir/OTP/architecture, `Mix.env()`, and `Mix.target()`—leaving the committed `mix.lock` untouched. Leave `MIX_BUILD_PATH`, `MIX_BUILD_ROOT`, `MIX_DEPS_PATH`, and `MIX_LOCKFILE` unset when using `.mix_sources.json`.

## Repository Verification Gates

From the `med_ex` checkout root, run:

```bash
mix deps.get
mix compile --warnings-as-errors
mix test
mix docs --warnings-as-errors
node --test test/*.mjs
./build_support/check_architecture.sh
./build_support/check_consumers.sh
```

What each gate verifies:

- `mix test`: Runs contract, property, canonical `MEX1`/`MEJ1` reference-vector, `ClockAlign`, `ControlInterlock`, `StreamWriter`, POSIX recovery/fault-injection, and browser WAV `Capture` suites.
- `node --test test/*.mjs`: Verifies `pcm_capture.js` and `pcm_worklet.js` framing, source selection, and 16-slot acknowledgement window bounds.
- `./build_support/check_architecture.sh`: Independently compiles and tests `core/med_core`, `core/med_capture`, and the root `:med_ex` package, enforcing zero forbidden dependencies, 1:1 module ownership, and pure-core call/AST boundaries.
- `./build_support/check_consumers.sh [source_root]`: Builds standalone Hex archives for `:med_ex`, `:med_ex_opus`, and `:med_ex_rtc` in a temporary directory and compiles + tests 8 fresh external Mix consumer projects (`direct` and unpacked `archive` × `headless`, `opus`, `rtc`, and `both`).

## Optional Maintainer Projections (`Weld`)

`Weld ~> 0.15.0` is isolated in `tools/maintainer/mix.exs` so the public `:med_ex` `mix.exs` carries no packaging dependency. Maintainers can generate or verify `.weld/` projections from `tools/maintainer`:

```bash
cd tools/maintainer
mix deps.get
mix weld.setup ../../build_support/weld.exs
mix weld.project ../../build_support/weld.exs --artifact med_ex --live
mix weld.project ../../build_support/weld.exs --artifact med_ex
mix weld.verify ../../build_support/weld.exs --artifact med_ex
```

- Live view: `.weld/live/med_ex` (regenerate after editing `mix.exs`, `VERSION`, `core/*/mix.exs`, or `build_support/weld.exs`).
- Full candidate: `.weld/full/med_ex/project`.
- Pass any projected directory to `./build_support/check_consumers.sh /path/to/projected/med_ex` to run the full 8-consumer matrix against that projection.
