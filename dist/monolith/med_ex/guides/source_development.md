# Source development

These instructions apply to the source repository checkout at
<https://github.com/nshkrdotcom/med_ex>. They are not needed when installing
`:med_ex` as a Hex dependency.

## Repository layout

| Path | Role |
| --- | --- |
| `core/med_rtc` | Capture, evidence, preview, canonical WAV rules, and `MedEx.Web` browser assets and tests. |
| `build_support/weld.exs` | Weld manifest projecting `core/med_rtc` into the single `:med_ex` Hex package. |
| `dist/release_bundles/` | Gitignored output directory where `mix weld.release.prepare` writes the generated `project/`, rendered `docs/`, and `.tar` archive. |

## Prerequisites (Ubuntu 26.04)

Install system packages:

```sh
sudo apt-get install -y git curl tar build-essential pkg-config libssl-dev
```

*(Install `libopus-dev` as well if compiling `membrane_opus_plugin` from source
instead of using precompiled binaries.)*

Activate the exact Erlang and Elixir versions pinned in `.tool-versions`
(`erlang 29.1.2`, `elixir 1.20.5-otp-29`) via `asdf` or `mise`.
Use the pinned Node `24.19.0` for the browser helper tests; the sibling Fabric
checkout uses the same version for its browser verification.

## Build, test, and prepare a release bundle

Update the root `VERSION` file when bumping MedEx. The workspace projects and
the Weld manifest share it, and the manifest derives the HexDocs projection tag.

```sh
./onboard.sh
mix ci
node --test core/med_rtc/test/*.mjs
mix weld.release.prepare
```

`mix weld.release.prepare` prints the path to the generated bundle under
`dist/release_bundles/med_ex/<version>-<digest>/`, containing:

- `project/` — standalone generated `:med_ex` Mix project (can be referenced as
  a local path dependency before Hex publication, or tested directly via
  `mix deps.get && mix test`).
- `docs/` — rendered ExDoc HTML preview (`docs/index.html`).
- `med_ex-<version>.tar` — exact Hex archive.
- `release.json` — source revision, verification checks, and SHA-256 digests.

From a sibling `med_fabric` checkout, `bash ops/qc_candidate.sh` prepares that
bundle and passes its exact `project/` path to the exam via `MF_MED_EX_PATH`.
It also runs the browser Node tests and checks that the three prepared assets
match those tested SDK sources byte for byte. The exam's candidate lockfile
lives under `_build/`; its committed Hex lockfile is not rewritten by this run.
