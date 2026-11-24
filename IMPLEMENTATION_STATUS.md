# Implementation status — November 24, 2026

The unreleased source now has a canonical `:med_ex` root, independent pure/capture proof projects, separate optional Opus and RTC providers, revision-1 signal contracts, MEX1/MEJ1 codecs, exact clock bounds, device-control decisions, a bounded per-stream writer and verified POSIX journal recovery. `VERSION` remains `0.2.0`. A source API revision is not a package release.

Legacy Capture/Evidence/WAV/Preview and browser assets remain represented by their new owners. The 29 retired MedRTC source files and its generated test outputs were removed. Historical component release notes are retained in `guides/history/med_rtc_changelog.md`.

## Runtime qualification

The SDK compiled with Elixir 1.20.5 and OTP 29.1.2. Its 57 root tests and both
independent compilation projects passed. The architecture check compared
34 compiled modules and exercised negative compiler traces. Five Node
PCM/worklet tests passed, and the three browser assets matched the baseline.

The consumer matrix exercised headless, Opus, RTC and combined installation
against direct, live and full sources and unpacked packages. An external Mix
consumer also verified prepared, archive and projection-branch sources with
the SDK checkout hidden. The published Weld 0.15.0 maintainer dependency
generated the projections.

The checked-in vectors were independently reconstructed from the MEX1 and
MEJ1 layouts and the semantic fingerprint specification. The permanent
`wire_frame_v1_test.exs` and `semantic_vectors_test.exs` tests verify their
bytes and hashes. The temporary reconstruction helper was retired.

The extension defaults pin the verified SDK base at
`83defa6d16e5062b3b027cb0e1dbec98bac38705`. The published MedEx 0.1.0 legacy
consumer passed its legacy contract and failed the revision-1 check with an
explicit diagnostic. Version 0.2.0 identifies the Git source in this work.

See [Source development](guides/source_development.md) for commands and
[Product horizon](guides/product_horizon.md) for hardware validation.
