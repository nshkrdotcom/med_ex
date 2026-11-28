# Engineering

Use Elixir ~> 1.20 and keep the implementation small. Every package, process,
mutable field and abstraction must serve an exercised requirement. Prefer pure
functions, one owner per fact and direct use of existing libraries. Delete unused
scaffolding and test guarantees that can fail.

## Quality checks

- README, documentation, and artwork-only edits need only checks relevant to
  the edited files. Skip code test suites, native checks, and release tooling
  unless explicitly requested.
- For code changes, run the checks that cover the affected behavior. For release
  qualification, run formatting, warning-free compilation, Credo, Dialyzer,
  ExUnit, ExDoc, and applicable Python, C, native, and detached gates. Verify
  integrations with real services and report evidence precisely.
- Report checks blocked by missing services or tooling as NOT RUN. Do not
  publish, reset data, delete evidence, or deploy without explicit authorization.

## Revision 2 architecture

- One waveform mechanism: StreamWriter plus immutable objects, journal and index.
- Receipt owns technical identity/progression. RecordingLimits owns capacities.
- Core is pure; capture owns effects. File is the sole production storage backend.
- Each consequential writer operation has explicit owner and fence. Unknown
  effects retire the writer; prove OS/worker quiescence before recovery/handoff.
- The host supplies exclusive OS root ownership. No multi-node writable failover.
- No browser assets or media provider interfaces in the base SDK. Opus and RTC
  own concrete APIs and have no base dependency. Never restore retired APIs.
- Only med_ex is a Weld package projection. Build med_ex_opus and med_ex_rtc
  directly with Mix from extensions. No provider projection or publication of
  private components. See build_support/release_matrix.json.
- Published requirements use bounded minor families. Exact candidate locks and
  archive checksums are qualification evidence; never invent checksum entries.

Read guides/technical_contract.md and guides/releasing.md before cross-package
changes. Changelogs retain factual history only.
