# Consumption, Extensions, and Verification

MedEx provides three ordinary Mix packages. The root project builds the base SDK
directly. Its private Core and Capture projects compile and test their boundaries
independently. The composition declaration in `build_support/composition.exs`
also selects the roots of the Weld base artifact. Each media extension has its
own portable Mix project and Weld artifact. `tools/maintainer` installs Weld
for maintainers and stays outside all three package dependencies.

## Choose a transport

The 0.3.x family implements contract revision 1
(`MedEx.Contract.api_revision() == 1`). The published 0.1.0 package provides
the original browser WAV and preview contract. The base examples below
select 0.3.0, with `med_ex_opus ~> 0.2.0` and `med_ex_rtc ~> 0.2.0`.
[Hex package history](https://hex.pm/packages/med_ex)

| Transport | Base project | Optional extension project |
| --- | --- | --- |
| Checkout path | `../med_ex` | `../med_ex/extensions/<artifact>` |
| Exact Git revision | Repository root | Same revision, `subdir: "extensions/<artifact>"` |
| Weld live path | `../med_ex/.weld/live/med_ex` | `../med_ex/.weld/live/<artifact>` |
| Weld full path | `../med_ex/.weld/full/med_ex/project` | `../med_ex/.weld/full/<artifact>/project` |
| Weld prepared path | `../med_ex/.weld/releases/med_ex/<identity>/project` | `../med_ex/.weld/releases/<artifact>/<identity>/project` |
| Tracked projection snapshot | Exact revision on `projection/med_ex` | Exact revision on `projection/<artifact>` |
| Hex | `{:med_ex, "~> 0.3.0"}` | `{:med_ex_opus, "~> 0.2.0"}` or `{:med_ex_rtc, "~> 0.2.0"}` |

Use ordinary Mix dependency declarations. A headless host needs only
`{:med_ex, "~> 0.3.0", path: "../med_ex"}`. When a host uses extensions with a
checkout or Git base, override their Hex dependency with that base source:

```elixir
[
  {:med_ex, "~> 0.3.0", path: "../med_ex", override: true},
  {:med_ex_opus, "~> 0.2.0", path: "../med_ex/extensions/med_ex_opus"},
  {:med_ex_rtc, "~> 0.2.0", path: "../med_ex/extensions/med_ex_rtc"}
]
```

You can replace each path with the corresponding projected path in the table.
For Git, use the same exact reachable commit for the base and any extensions:

```elixir
[
  {:med_ex, "~> 0.3.0", github: "nshkrdotcom/med_ex", ref: commit, override: true},
  {:med_ex_opus, "~> 0.2.0", github: "nshkrdotcom/med_ex", ref: commit,
   subdir: "extensions/med_ex_opus"},
  {:med_ex_rtc, "~> 0.2.0", github: "nshkrdotcom/med_ex", ref: commit,
   subdir: "extensions/med_ex_rtc"}
]
```

Set `commit` to the verified MedEx revision in your Mix project. Omit either
extension when the host does not use it. Configure `:preview_provider` for
Opus and `:rtc_provider` for WebRTC.
[Host Integration and Browser Compatibility](host_integration.md)

## Work on an extension

Each extension declares the normal Hex dependency `{:med_ex, "~> 0.3.0"}`
and keeps its own `VERSION`. The published 0.1.0 provider packages can
resolve MedEx 0.3.0 within that requirement.

For a local edit, run the real provider suites from fresh outer Mix consumers
with the explicit path dependencies above:

```sh
./build_support/check_consumers.sh --quick
```

Use `--quick --profile opus` or `--quick --profile rtc` for a single
provider. The `base` and `both` profiles are also available.

For standalone extension tests before publication, use a signed private Hex
registry containing the actual three candidate tarballs and their third-party
dependencies. In that registry context run `mix deps.get`, `mix test` and
`mix docs --warnings-as-errors` inside each extension. The standalone test
helpers configure the provider being exercised. Fetch the base through normal
Hex SCM for this lane. The outer path consumer checks source builds, and the
registry lane checks the package requirements.

The Opus package runs a vendored-libopus encoder as an OS process over a Port. RTC uses ExWebRTC and ExRTP.
Install a C toolchain and the platform prerequisites for the profile you use.
[Native build prerequisites](host_integration.md#prerequisites)

## Build and check the artifacts

The maintainer project uses Weld 0.19.0 from Hex. Run the following Mix tasks
from `tools/maintainer` using the relative manifest path below.

```sh
cd tools/maintainer
mix deps.get
manifest=../../build_support/weld.exs
mix weld.setup "$manifest"
mix release.status "$manifest"
for artifact in med_ex med_ex_opus med_ex_rtc; do
  mix weld.project "$manifest" --artifact "$artifact" --live
  mix weld.project "$manifest" --artifact "$artifact"
done
```

Live artifacts link source directories and check structural inputs on a fresh
Mix invocation. Edit and format in the source checkout. Refresh with the same
`weld.project --live` command after changing definitions such as a scoped
`mix.exs`, `mix.lock`, `VERSION`, the composition declaration or the manifest.
Use a full project for Hex packaging or portable verification. The root
checkout also builds its own direct base Hex archive.

Use `mix weld.verify "$manifest" --artifact <artifact>` to build and verify
each full project. Verification of either extension needs the signed registry
before it resolves the base requirement. From the MedEx root, run the
following with the path to the installed maintainer project or candidate Weld
checkout:

```sh
./build_support/check_consumers.sh --registry -- sh -eu -c '
  cd "$1"
  for artifact in med_ex med_ex_opus med_ex_rtc; do
    mix weld.verify "$2" --artifact "$artifact"
  done
' registry /absolute/path/to/weld-invoker "$(pwd)/build_support/weld.exs"
```

Run `mix release.prepare` with the same manifest and artifact in that registry
context to prepare portable projects from a clean committed source. Use
`mix release.track` with the same manifest and artifact to record a prepared
snapshot on its local projection branch.

For provider releases, verify and prepare against the public Hex base. From
`tools/maintainer`, select `med_ex_opus` or `med_ex_rtc` and carry the full
identity printed by prepare through the handoff.

```sh
manifest=../../build_support/weld.exs
artifact=med_ex_opus
mix release.prepare "$manifest" --artifact "$artifact"
mix release.status "$manifest" --artifact "$artifact"
```

Set `identity` to the full bundle identity and `tag` to the default tag from
status. Run the dry run before pushing the release tag, and archive after Hex
confirms publication.

```sh
mix release.publish "$manifest" --artifact "$artifact" --identity "$identity" --dry-run
mix release.track "$manifest" --artifact "$artifact" --identity "$identity" --tag-release --push
mix release.verify_tag "$tag" "$manifest"
mix release.publish "$manifest" --artifact "$artifact" --identity "$identity" --tag "$tag"
mix release.archive "$manifest" --artifact "$artifact" --identity "$identity"
```

The annotated tag and projection commit record the bundle identity. Local
bundles and publish workspaces live under the checkout's `.weld/` directory.

## Repository checks

Run from the MedEx root:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs --warnings-as-errors
node --test test/*.mjs
./build_support/check_architecture.sh
./build_support/check_architecture.sh .weld/full/med_ex/project
./build_support/check_architecture.sh .weld/live/med_ex
./build_support/check_consumers.sh --quick
```

The architecture gate compiles and tests the two independent components and the
base SDK. With a base projection path, it checks projected test inputs, actual
BEAM ownership, application metadata, graph closure, package scope and browser
asset bytes. The direct checkout formatter covers source files and tests.

Use `./build_support/check_consumers.sh --full` for the transport matrix after
preparing the three live, full and prepared projects and the Git snapshots.
The gate requires a clean source commit and prepared releases bound to that
revision. Each local `projection/<package>` ref must have the same paths,
Git executable modes and file bytes as its prepared project.
The matrix runs base, Opus, RTC and combined profiles in independent contexts.
It inspects actual Hex archives and resolves the packages from a temporary
signed registry. Use `--transport live` or another named transport for a
single lane. Use `--evidence /absolute/path/to/new-directory` to retain command
logs. The quick lane works from the checkout without Weld.

## Daily feedback and resumable qualification

Run the affected check against your current commit for unstaged, staged and
untracked changes. Use a merge base or another Git revision to include commits.

```sh
./build_support/check_consumers.sh --affected HEAD --plan
./build_support/check_consumers.sh --affected HEAD
./build_support/check_consumers.sh --functional
```

A private component or shared asset change selects all downstream SDK profiles.
A provider change selects its single-provider and combined profiles. Guide
changes select docs and package checks. Unknown inputs take the conservative
path.

Use `--optimized` after preparing and tracking the three official artifacts.
The direct profiles run the full consumer suites. Every transport still
resolves its own dependency lock, compiles and starts the installed SDK, and
runs the ownership, asset and raw-stream smoke tests. Provider suites run
again whenever the effective source, compiled code, compiler options, app
metadata, dependency lock, assets or test inputs differ. For example, a
dependency macro can embed its compilation path in a provider BEAM and make
two installations distinct. The original `--full` remains available as
`--strict-full`.

```sh
./build_support/check_consumers.sh --optimized --jobs 2 --evidence /private/new-medex-evidence
./build_support/check_consumers.sh --resume /private/new-medex-evidence --jobs 2
```

The evidence directory contains the cell receipts, lock and module inventories
and timing logs. Resume checks current inputs and the hashes of recorded
outputs. The optimized run keeps a per-directory synthetic signing key with
private permissions for registry cell reuse. Keep the directory private and
remove the key when retiring the evidence from active qualification.

The optional workstation runner operates on sibling checkouts and reports
what it selected. Ordinary Mix commands remain available in each project.

```sh
./build_support/qualify_ecosystem.sh plan --base HEAD
./build_support/qualify_ecosystem.sh dev --base HEAD
./build_support/qualify_ecosystem.sh full --jobs 2 --evidence /private/ecosystem-evidence
./build_support/qualify_ecosystem.sh status --evidence /private/ecosystem-evidence
./build_support/qualify_ecosystem.sh resume --jobs 2 --evidence /private/ecosystem-evidence
```

Full qualification expects MedEx at the verified remote revision and Fabric
at the corresponding pin. Use `--gate medex-matrix` to qualify the local
artifact and consumer gates before the MedEx push. See `--help` for strict
and cache-controlled runs. The official maintainer lock continues to resolve
published Weld 0.19.0.
