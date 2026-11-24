# Implementation status — November 24, 2026

The unreleased source now has a canonical `:med_ex` root, independent pure/capture proof projects, separate optional Opus and RTC providers, revision-1 signal contracts, MEX1/MEJ1 codecs, exact clock bounds, device-control decisions, a bounded per-stream writer and verified POSIX journal recovery. `VERSION` remains `0.2.0`. A source API revision is not a package release.

Legacy Capture/Evidence/WAV/Preview and browser assets remain represented by their new owners. Retire the old `core/med_rtc` source paths after reconciling local changes; leaving duplicate obsolete module owners is not a supported composition. Historical component release notes are retained in `guides/history/med_rtc_changelog.md`.

## Observed checks

- Five legacy Node PCM/worklet tests passed with no skips in the relocated layout.
- The three canonical browser assets were byte-identical to the supplied baseline.
- Independent MEX1, canonical metadata and semantic fingerprint fixture reconstruction passed.
- Shell syntax, Git whitespace and inspected source/package inventories passed. A local filesystem primitive probe exercised file/directory sync and hard links; it did not qualify the Elixir adapter or a production mount.

No Elixir/OTP runtime was available. Compiler/formatter, ExUnit, native providers, BEAM boundary traces, package consumers and crash/recovery timing remain runtime gates. The independent code review corrected provenance serialization, strict receipt fields and finite standalone encoder deadlines; their regressions remain unexecuted.

## Required closure

Run the root, source-proof, architecture, native-provider and external-consumer gates in `guides/source_development.md`. Exercise storage fault points and all receipt/fence boundaries on the intended filesystem. The SDK's local process exclusion does not replace the host's cross-OS-process ownership; Fabric provides the lab host lock. Native crash containment requires a separate OS BEAM.

Initially select local source explicitly. Replace provisional GitHub branch defaults in both extensions and downstream consumers with the actual verified reachable base SHA, regenerate real locks, and verify fresh clone defaults. Existing legacy Hex 0.2.0 cannot establish revision-1 API compatibility. No new MedEx version or publication is part of this work.

Keep the golden fixtures, ExUnit invariants, negative boundary tests, legacy Node tests and consumer scripts. `build_support/check_vectors.py` is an optional independent verification aid; after its evidence and equivalent permanent byte assertions are retained, it may be removed with its documentation references. See the separate QC handoff for the exact retirement and cleanup sequence.
