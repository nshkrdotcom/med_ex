# Retained source-check evidence — November 26, 2026

These are observed source-check results, not native release qualification.
`results.json` records actual commands, exits, scope and environmental limits.
The per-command logs preserve the corresponding output. `source_inventory.json`
records source bytes and executable modes, excluding Git metadata, generated
caches and this qualification directory; it is not a prepared Hex inventory.

Elixir, Erlang and Mix were unavailable. No formatting, compilation, ExUnit,
Credo, Dialyzer, ExDoc, native PostgreSQL/HAPI/browser/RTC/TURN, physical disk,
Weld generation, direct Hex packaging or full soak success is claimed. Execute
the full current release guide and authoritative acceptance gates on
the exact committed candidate, fix defects and rerun affected checks.

The JavaScript suite executes the shared receipt corpus and browser/worklet
logic under Node. The Python build and report fixtures are targeted regressions.
Neither substitutes for a real installed browser/native system run.

The C encoder compiled with warnings as errors against installed system libopus
1.5.2 and transient ABI declarations. The full seven-case protocol invocation
returned exit 1: five portable cases passed; two process-lifetime cases errored
at their required procfs capability precondition. They were not converted to
passing skips. This is not a pinned-archive build or lifecycle qualification.

Nothing was published or activated. Candidate evidence cannot prove official
publication, official downstream lock refresh or final official qualification.
