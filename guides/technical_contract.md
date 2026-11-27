# Technical contract — API revision 2

This guide defines the installed MedEx interfaces used by the common acquisition
hosts. `MedEx.Contract.api_revision/0` returns `2`. The base package is `med_ex`
0.4.0; independent concrete capabilities are `med_ex_opus` and `med_ex_rtc`
0.3.0. A host checks revision before starting listeners, source admission,
writers or native peers. There is no compatibility facade or alternate recording
mechanism. `StreamWriter` plus File objects, journal and index is the waveform
path. The supported export inventory is enforced by `build_support/public_api.exs`.

## Ownership and pure values

`StreamSpec`, `SampleFrame`, `IntegritySpan`, `SegmentRef`, `StreamIndex`, clock
values, `StreamCursor`, `ControlInterlock`, `Receipt`, canonical serialization
and wire parsing are pure. They do not authenticate callers or read storage,
SQL, clocks or configuration. Hosts supply those facts at the effect boundary.
`Storage.File` is the sole production storage implementation. Its behavior,
Transfer and Usage are internal resource contracts, not provider extension APIs.

`StreamCursor.plan/2` owns source frame/gap progression. It yields a planned
cursor, replay request, exact duplicate or technical refusal. Hosts and device
spools must use it rather than duplicate sequence/sample arithmetic. The
full-frame fingerprint includes identity, sequence, sample coordinates,
configuration epoch and payload. A transport-byte hash is a separate fact.

## Canonical receipts

A receipt has exactly these fields:

| Field | Meaning |
| --- | --- |
| `stream_id`, `source_epoch`, `descriptor_ref` | Exact source descriptor identity |
| `fence`, `journal_id` | Attempt and actual journal incarnation |
| `journal_generation`, `journal_digest` | Verified commit count and digest |
| `accepted_sequence`, `accepted_sample` | End-exclusive volatile accepted cursor |
| `durable_sequence`, `durable_sample` | End-exclusive verified durable cursor |

`Receipt.parse/1` returns `{:ok, %MedEx.Receipt{}}` or a structured error.
Wire maps have exactly eleven string keys. All counters, including source
epoch, are canonical unsigned decimal strings; JSON numbers, signs, leading
zeros and unknown keys are rejected. Digests are lowercase SHA-256 hex. Source
epoch is unsigned 32-bit, source cursors are unsigned 64-bit, and journal
generation is 1–100,000. Accepted cursors cannot precede durable cursors.
`Receipt.to_map/1` is the inverse serialization for validated typed receipts.

`validate_identity/2` requires the expected stream, source epoch, descriptor and
fence, and checks journal ID if supplied. `durable?/1` is true only when both
accepted cursors equal both durable cursors. `durable_prefix/1` removes volatile
accepted progress; it does not establish that any bytes were committed.
`observe/2` checks identity, monotonic durable coordinates and generation,
exact same-generation equality, and changed digest on generation advance.
An observation may skip multiple commits. `committed_successor/3` additionally
requires exactly one new journal generation and exact planned cursor.
`exact_prefix?/2` requires fully durable exact equality; accepted-only state
cannot pass. Recovery values may be supplied as the second argument.

`handoff/3` requires unchanged descriptor identity, changed fence and journal
incarnation, successor generation one and exact imported predecessor cursors.
The explicit context contains `previous`, `successor`, `authenticated: true`,
`quiescent: true`, and `imported`. A host uses `authority: :verified_storage`
with actual File recovered-prefix facts, including full-journal provenance.
A source uses `authority: :authenticated_host` only after authenticating the
current host transport and its exact predecessor/import assertion; its imported
value is the canonical predecessor receipt. An arbitrary wire flag cannot
establish either context. A lost ACK can leave the device watermark behind the
host predecessor; validate that observation first, then the handoff, then local
retained source coverage before persisting a new watermark and reclaiming data.

`terminal_receipt(index, recovered, previous)` returns the exact typed terminal
receipt only when index, installed index digest, full journal provenance,
identity, terminal state and cursor agree. It requires one terminal commit
beyond the independently validated flushed prefix, or exact idempotent terminal
equality. It never manufactures terminal truth from an accepted cursor.

The shared executable corpus is
`core/med_core/test/fixtures/receipt_vectors_v2.json`; its adjacent SHA-256 file
pins the canonical bytes. Elixir, browser and device tests consume those same
bytes, with seed `20261126`, through their public receipt paths.

## Fenced writer

```elixir
{:ok, writer} = MedEx.StreamWriter.start_link(
  owner: self(), stream: descriptor, fence: fence, artifact_dir: attempt_dir,
  root_owner: root_guard, limits: %{checkpoint_ms: :manual}
)
{:ok, accepted} = MedEx.StreamWriter.push(writer, fence, frame, 1_000)
{:ok, durable} = MedEx.StreamWriter.checkpoint(writer, fence, 5_000)
true = MedEx.Receipt.durable?(durable)
{:ok, terminal} = MedEx.StreamWriter.finish(writer, fence, 5_000)
```

The complete consequential API is `push/4`, `record_gap/4`, `checkpoint/3`,
`finish/3`, `interrupt/4`, `receipt/3` and `stats/3`, each with explicit fence
and positive timeout. `start_link/1` accepts only `:owner`, `:stream`, `:fence`,
`:artifact_dir`, `:root_owner`, `:limits` and optional typed `:predecessor`.
There is no runtime storage-selector option. An unrelated caller or stale fence
is rejected before storage effects. An OTP supervisor can start the child while
the explicit source coordinator remains owner.

Push and checkpoint return `{:ok, %Receipt{}}`; accepted data is not durable
until the receipt says so. Receipt reads return that same shape. Stats return
`{:ok, map}` with actual usage, pending/peak bytes and frames, and limits.
Finish and interrupt return `{:ok, %MedEx.Storage.Terminal{index, receipt,
recovered}}` after actual installed-index verification. Repeating finish returns
the exact terminal value. Sealed writers reject new frames, gaps, checkpoints
and interruptions. A terminal writer holds no writable handle.

A proven refusal returns `{:error, {:not_committed, reason}}`. Capacity refusal
is `{:error, {:not_committed, {:capacity, limit}}}` and preserves the accepted
prefix for explicit settlement. Exceptions, malformed storage results and
uncertain calls return `{:error, {:outcome_unknown, reason}}`, retire the writer,
and require recovery before any successor. Timeout does not prove cancellation.
An internal owner/fence admission handshake shares the public operation's one
deadline. If that read-only handshake times out, no source operation was
submitted: `writer_authorization_unavailable` is a known refusal and cannot
retire another owner's writer. A submitted operation has a deadline checked
before dispatch; its uncertain timeout retires the owner-authorized writer.
Never blindly retry an unknown effect. Owner death never flushes pending source.
Manual checkpoint mode is required when host SQL/authority admission surrounds
every effect. Automatic mode is for independently authorized standalone hosts;
it reports `{:med_ex_durable, writer, receipt}` or
`{:med_ex_storage_failed, writer, reason}` to the owner.

Storage resources transfer through an internal typed Transfer envelope. The
writer adopts the returned handle before interpreting success or failure.
Before an envelope transfers ownership, the adapter cleans newly acquired
resources; after transfer the writer owns cleanup. Closing is idempotent.
Tests exercise state-replacing adapters with actual allocated file handles,
malformed results, exceptions and before/after-journal fault barriers.

## Shared recording limits

`RecordingLimits.new/1` accepts a bounded map/keyword list or typed limits.
Budgets can be lowered but cannot exceed the format maxima:

| Budget | Default and maximum |
| --- | ---: |
| Pending PCM | 262,144 bytes |
| Pending frames | 16 |
| Checkpoint interval | 250 ms; `:manual` disables the timer |
| Logical duration | 1,800 seconds |
| Raw artifact PCM | 536,870,912 bytes |
| Frames | 1,000,000 |
| Integrity spans | 100,000 |
| Journal generations | 100,000 |
| Journal bytes | 268,435,456 |
| Imported predecessor depth | 32 |

Journal content is capped at 65,424 canonical bytes per record and has a
112-byte envelope. Admission accounts for actual encoded metadata, pending
flushes and a worst-case canonical terminal envelope. It reserves terminal
journal generation, bytes and integrity-span capacity before accepting source.
Sample-only gaps consume a source record and can advance samples without a
sequence delta. Minimum generation budget is three. Logical limits, including
span and journal accounting, also apply during journal replay. A lower host
policy is not a reason for the format reader to reject an already valid prefix.

## Exclusive root and File operations

The deployment has one writable service per evidence namespace. Its existing
root guard must hold a real OS `flock`, own the service root, retain a stable
incarnation token, and fail stop on lost lock. It must not silently reacquire
ownership around surviving workers. A standalone host provides the same guard
contract; a BEAM process name or per-writer lock is insufficient.

File asks the supplied local live `root_owner` PID:

```elixir
GenServer.call(root_owner, {:med_ex_root_ownership, absolute_attempt_dir}, 1_000)
# {:ok, %{root: absolute_service_root, token: stable_reference}}
```

The guard answers only while its actual lock is live and the requested path is
within its root. File checks a real service-uid-owned root directory, no group
or other write permissions on that root, no symlink ancestors, and trusted
uid/root-owned ancestors. Sticky writable ancestors such as `/tmp` are allowed
because they protect the owned next directory from replacement. The concrete
ownership check currently uses Linux procfs; other platforms fail closed pending
qualification. Ownership tokens are rechecked before mutations and verified
reads. Root ownership does not replace the host authority/effect gate.

`Storage.File.recover(dir, opts)` is read-only: it never truncates, appends or
installs an index. Options are `stream:`, `fence:`, `root_owner:`, optional fully
durable `known_receipt:`, and a 1–30,000 ms `timeout:`. It verifies journal chain,
source decisions, referenced PCM bytes and imported predecessor journals. It
returns `{:ok, %RecoveredPrefix{artifact_dir, stream, fence, receipt, cursor,
index, index_digest, terminal_recorded, index_status, sealed, torn_tail,
provenance}}`. `index_status` is `:absent` or `:installed`; terminal journal truth
and index installation are separate facts. Provenance binds the full-journal
verification to the root owner/token and exact receipt. Orphan objects are not
evidence. A torn incomplete tail is distinct from a bad complete record/chain.

Recovery obtains the same local lock as the writer. A recovery worker that
outlives its caller deadline retains that lock until the actual operation ends;
its late response is discarded. Successful recovery under the same live root
owner proves no local writer/recovery worker simultaneously holds that attempt.
The host must still establish prior service/OS quiescence and retain its own
effect gate across SQL failure, owner death and unknown effects. A dead ingress
PID or a timed-out call alone does not establish quiescence.

`Storage.File.reconcile_terminal(dir, opts)` explicitly installs only the exact
missing immutable index of a verified terminal journal after quiescence. It is
idempotent. A conflicting/corrupt index refuses without overwrite. It does not
convert a live prefix into a terminal journal. Index content schema is version
2, journal identity content is `medex.journal.v2`; obsolete schema content is
not accepted. MEX1 frame and MEJ1 envelope byte encodings remain unchanged.

## Bounded promoted-evidence reads

Load an index once with `read_verified_index(dir, index_digest, expected)`.
`expected` is an atom-key map containing `root_owner`, `manifest_digest`,
`index_digest`, `stream_id`, `source_epoch`, `descriptor_ref`, `fence` and
`journal_id`. The host supplies these from an authorized promoted manifest.
The call verifies canonical immutable index bytes/digest, identity and root
provenance and returns `{:ok, %VerifiedIndex{}}`.

`read_verified_segment(verified_index, first_sample, expected)` returns exactly
`{:ok, pcm_bytes}` for the segment at that first sample. It rechecks the same
manifest/index/descriptor/fence/root binding, unchanged index filesystem stamp,
regular non-symlink object, exact byte length and SHA-256 of the very bytes
returned. It does not replay the journal per segment. A changed root token,
manifest binding, index stamp, missing segment, symlink or corrupt payload fails
closed. Browser/cache authorities must use immutable manifest/index identities
and bounded requested windows, not mutable paths or a prior unrelated hash.

`MedEx.Format.Wav.header/4` is the only WAV helper. It accepts encoding
`:s16le`, `:s24le` or `:s32le`, channel count, positive integer sample rate and
aligned payload byte count, returning `{:ok, 44_byte_header}` or an error.
The host streams verified index segments after that header. The helper does no
I/O, path lookup, large allocation or resampling. Noninteger source rates must
be handled explicitly by host policy.

## Acquisition wire and credit

All common control JSON uses `schema: "medex.acquisition.v2"`. `Control.encode/2`
and `decode/2` enforce a 16,384-byte limit, exact operation key inventories,
duplicate-key rejection, bounded nesting/maps/lists/strings and canonical
unsigned decimal counters. `Control.uint64/1` provides that scalar parser.
Unknown revisions, keys, operations and malformed JSON fail before admission.
Hello has `api_revision: 2`, operation ID, acquisition, encounter, profile, boot
and descriptors; browser creation proof and proposed credit limits are optional
profile-specific fields. Profiles are `paired_exam`, `plx_spot_check` and
`browser_microphone`. PLX can send an empty descriptor map.

Every post-admission request and authoritative reply carries `operation_id` and
nested `binding`. Binding includes acquisition, profile, generation and a unique
server-issued connection incarnation; stream operations additionally bind
stream, fence and journal ID. Durable receipts remain nested unmodified
canonical receipt objects. Open operations may send top-level acquisition and
generation only as equality assertions against binding. The separate top-level
lease is secret host authority; it is not part of the public binding.

Supported operations comprise hello/admitted, stream/monitor open/close,
gap/checkpoint/finish, acquisition/event inventory finish, heartbeat/replies,
command/readback/state query, command results, measurement/status events,
probe/anchor clock observations, accepted/durable/replay/terminal/sealed replies,
and exact refusal/error. The codec source is the complete strict field inventory.
Heartbeat uses a nonce and bounded `remaining_ms`; command budget is separately
bounded `command_remaining_ms`. A reply cannot renew a stale binding. Application
meaning and authenticated authority are checked by the host/device transition
owners after strict parsing.

`MedEx.Wire.Credit` owns outstanding charge arithmetic. `new/3` admits at most
15 source records and 262,144 wire bytes. `reserve/3` takes an exact bound
operation with ID, fingerprint, encoded bytes and end-exclusive sequence/sample
coordinates. Each complete MEX1 frame includes its 48-byte header; each gap
costs one slot and its full canonical wire bytes. Exact retries do not create a
new charge. `acknowledge/3` releases only source records covered by a fully
durable receipt after caller Receipt identity/progression and retained coverage
checks. `refuse/4` releases only exact known-refused operation credit; it never
deletes source. `invalidate/1` discards old connection credit. Numeric sequence
deltas, accepted replies and elapsed time never grant credit.
`lookup/3` returns the exact outstanding operation for the current binding, so
accepted/refused reply validation does not depend on ledger representation.

## Command interlock and providers

`ControlInterlock.request/3` and `step/2` are pure and receive explicit authority
expiry, boot, generation, target, command ID/fingerprint, expected configuration
epoch and source watermarks. Intent must persist before dispatch. Timeout retains
an unknown historical boundary and requires exact historical result readback.
`{:historical_result, result}` must match ID/fingerprint/boot/target/generation;
applied results carry the next epoch and explicit application observation/sample
boundary. Reading current gain does not prove a prior command applied. Freezing
prevents late mutation. `device_decide/3` returns a validated persisted exact
result before considering expiry, and never reapplies an expired unseen command.

Concrete optional APIs and their platform/test requirements are documented in
[`med_ex_opus`](../extensions/med_ex_opus/README.md) and
[`med_ex_rtc`](../extensions/med_ex_rtc/README.md). Hosts own preview backpressure,
media clock mapping, peer lifetimes and authorization. The base SDK contains no
browser assets, preview registry, media provider behaviors, encoder wrappers or
provider environment selection.

## Evidence status

ExUnit, compilation, formatting, Credo, Dialyzer, ExDoc, native codec, real
WebRTC/TURN and detached-consumer gates are separate. Source and Python fixture
checks do not substitute for unavailable BEAM/native integration runs. Report
an unavailable gate as **NOT RUN** with its missing prerequisite. The release
matrix and qualification tooling bind exact candidate archives and locks; a
runtime feature implementation is not itself a release qualification.

### Physical filesystem exhaustion lane

`core/med_capture/test/storage_enospc_test.exs` fills a dedicated disposable
Linux ext4 loop mount independently during object installation, journal append
after object installation, and terminal-index installation. It verifies the
actual recovered prefix and explicit terminal reconciliation after freeing its
own filler. The ordinary suite excludes the `:enospc` tag unless a fixture is
selected. This is a separate **NOT RUN** native gate until executed.

An operator must supply a new otherwise empty ext4 loop mount with 4,096-byte
blocks, a service-owned root with mode 0700 and a marker named
`.med-ex-enospc-fixture.json` at the mount root. The marker has exactly:

```json
{"schema":"medex.enospc_fixture.v2","mount":"/absolute/disposable/mount","source":"/dev/loop7","max_fill_bytes":134217728}
```

Use the actual absolute mount and device returned by `findmnt`, and a bounded
fill ceiling larger than that disposable filesystem (for example a 64 MiB
mount and the 128 MiB ceiling above). Only the marker and filesystem-created
`lost+found` may exist initially. The test checks the real mount type/device,
identity, block size and inventory before allocating a unique case directory;
it never creates or reformats a filesystem. Run:

```sh
MED_EX_ENOSPC_ROOT=/absolute/disposable/mount mix test core/med_capture/test/storage_enospc_test.exs --include enospc
```

An explicitly selected missing, non-loop, non-ext4, shared, mismatched or
unmarked fixture fails the gate. Tests remove only their own case directory and
filler; the operator retains responsibility for the dedicated mount lifecycle.
