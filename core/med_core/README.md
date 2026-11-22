<p align="center">
  <img src="assets/med_core.svg" width="200" height="200" alt="MedCore logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex">
    <img alt="GitHub: med_ex" src="https://img.shields.io/badge/GitHub-med_ex-0b0f14?logo=github" />
  </a>
  <a href="LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# MedCore

`med_core` is the pure functional core of [MedEx](../../README.md). It has zero `GenServer`s, zero network calls, zero filesystem I/O, and zero wall-clock reads: every live-session transition is a deterministic `{next_session, effects}` step from `MedCore.Session.step/2`.

---

## Session facts

The pure reducer binds acquisition identity to a session, keeps recording reports separate from preview interruptions, and preserves a conflict across repeated starts and redelivery. The reducer returns facts for the caller. The caller owns transport, capture execution, and clinical acceptance.

Run `mix test` here for the focused reducer tests.
