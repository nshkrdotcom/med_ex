# Source development

These instructions apply to the source repository checkout at
<https://github.com/nshkrdotcom/med_ex>. They are not needed when installing
`:med_ex` as a Hex dependency.

## Repository layout

| Path | Role |
| --- | --- |
| `core/med_rtc` | `MedEx.Capture`, `MedEx.Evidence`, `MedEx.Preview`, WAV writer, and private Membrane Opus encoder. |
| `core/med_web` | `MedEx.Web` asset locator and browser JS (`session_hook.js`, `pcm_capture.js`, `pcm_worklet.js`). |
| `build_support/weld.exs` | Weld manifest projecting `core/med_rtc` and `core/med_web` into the single `:med_ex` Hex package. |
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

## Build, test, and prepare a release bundle

```sh
./onboard.sh
mix ci
node --test core/med_web/test/*.mjs
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
