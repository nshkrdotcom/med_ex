# Source development and independent consumption

`build_support/composition.exs` declares the base membership, version, docs and
assets once. The root Mix project is a development consumer of that declaration.
Run `mix setup` and `mix quality` for combined SDK/providers plus independent
Core/Capture boundaries, tooling regressions and compiled ownership. The root
commands and precise scopes are documented in README. A focused standalone
architecture rebuild is available as `build_support/check_architecture.sh`;
consumer matrices use the already-built proof inventories from root quality
and fail if they are absent. They do not repeat the ordinary source suites.
Browser acquisition assets/tests live in Fabric; the SDK has no empty Node gate.

Only `med_ex` is projected/prepared/tracked by Weld. `extensions/med_ex_opus` and
`extensions/med_ex_rtc` use their own `mix.exs`, package inventory, locks and
`mix hex.build`. Their dependencies do not include the base SDK. No provider
projection branch or generated project is a supported input.

Supported source proof uses root/direct projects, exact Git refs with actual
provider subdirs, base live/full/prepared/tracked views, detached archives and a
signed candidate registry. Projection variants apply only to the base; do not
multiply independent provider tests by every base projection form.

```sh
./build_support/qualify_projects.sh sdk
cd extensions/med_ex_opus
mix deps.get --check-locked
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
mix docs --warnings-as-errors
python3 test/build_test.py
python3 test/native_protocol_test.py
```

Run equivalent declared checks for RTC, including actual independent receiver
negotiation. Opus requires a real pinned libopus build and decode from the exact
package, in addition to fixture-backed native protocol tests.

Fabric selects development dependencies through `.mix_sources.json` only. Path
sources declare current versions and API revision; Git refs are exact 40-character
commits. Source lanes isolate lock/deps/build contexts and never mutate normal
locks. Detached consumers use normal Hex requirements and exact qualified locks.
See [release gates](releasing.md) before constructing any candidate.
