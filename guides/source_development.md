# Local source and verification

From the checkout root, run:

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
node --test test/*.mjs
./build_support/check_architecture.sh
./build_support/check_consumers.sh
```

The ordinary root never runs Weld, MWS or a checkout bootstrap. Development
documentation uses the development-only ExDoc dependency. The two source-proof
projects build in their own directories. The consumer check creates fresh Mix
projects under a temporary root, tests all four headless/Opus/RTC combinations,
builds Hex archives and consumes their unpacked contents. It needs a working
Mix/Hex toolchain and the native prerequisites below.

## Selecting extensions

Install `:med_ex_opus` and/or `:med_ex_rtc` in the consuming application. Select a
single top-level `:med_ex` source (use `override: true` to converge a compatible
transitive dependency). Direct path examples are `../med_ex`,
`../med_ex/extensions/med_ex_opus`, and `../med_ex/extensions/med_ex_rtc`.
For a checked/published Git commit, use the full checkout and the matching
`subdir` on each extension. The independent extensions contain local copies of
their version, license and source selector for portable archives.

When running an extension as the top-level Mix project, place the optional
`.mix_sources.json` alongside the repository root Mix project, or alongside the
extension Mix project in a standalone archive:

```json
{"med_ex":{"path":"."}}
```

The path resolves relative to the JSON file. A missing selection uses the
committed tuple. Path, full/live paths, GitHub/Git with one ref/tag/branch and
Hex/repo are supported. A selected source context separates lock, deps and
build state by project, source, toolchain, target, environment and baseline lock.
A full candidate also contributes its content identity. Unset MIX_BUILD_PATH, MIX_BUILD_ROOT,
MIX_DEPS_PATH and MIX_LOCKFILE for alternate contexts. Unselected providers
are inactive. Mix validates dependency identities and requirements at fetch/build.
There is no automatic sibling SDK selection.

The extension defaults pin the verified SDK base at
`c031a38a9e28fe6bccf1358d8f41fa419aa708d2`. A consumer of both providers can
select their verified source revision and use its own matching `:med_ex`
dependency with `override: true`. For local development, select the checkout
explicitly. The SDK product version remains `0.2.0`.

For a packaged legacy 0.1.0 user, keep existing host calls, configure both
providers explicitly when migrating to this source, and replace old direct
`:med_rtc` dependencies with `:med_ex`. Native RTC/Opus build prerequisites
apply only when installing those extensions.

## Optional projection

Weld 0.15.0 lives in `tools/maintainer`. From that directory use the compatible
Weld dependency and run:

```sh
mix deps.get
mix weld.project ../../build_support/weld.exs --artifact med_ex --live
mix weld.project ../../build_support/weld.exs --artifact med_ex
```

The live path is `.weld/live/med_ex`; the full path is
`.weld/full/med_ex/project`. Structural changes require live regeneration.
Tests using a prepared project or projection branch should rerun the same
consumer checks with that root supplied as the first argument. Preparing and
publishing a new product package are separate release decisions.

Rendered documentation is generated locally with `mix docs`. The permanent
MEX1 and MEJ1 fixtures were independently constructed and their byte and hash
assertions run with `mix test`. Generated release evidence can be stored
outside the checkout, together with its revision and checksum.
