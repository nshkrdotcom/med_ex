# Stream recording and reconciliation

Create a `MedEx.StreamSpec` with acquisition, authenticated source, boot and
stream IDs, source epoch, modality, encoding, channel order/calibration, rational
sample rate, clock qualification, processing history and negotiated capabilities.
`MedEx.Serialization.descriptor_ref/1` computes the hash of the canonical
descriptor excluding its self-reference. Persist its final fields and digest in
the host reservation. `Serialization.stream_spec/1` reconstructs the typed value
from the map emitted by `Serialization.to_map/1`. A valid digest string alone
does not prove the host has verified that binding.

A stream starts at sequence and sample zero. A frame covers a half-open interval
of complete simultaneous channel rows. The v1 MEX1 header is 48 bytes. It carries
a per-stream handle, epoch, configuration epoch (or unknown), sequence, first
sample, count and native payload length. Authenticate the connection and look up
the reservation before creating a `SampleFrame`. Wire SHA-256 is a transport
observation. `FrameFingerprint.of/1` hashes the independently bound semantic
identity with the domain `medex.frame.v1\0` and exact payload hash.

```elixir
{:ok, writer} = MedEx.StreamWriter.start_link(
  owner: self(), stream: spec, artifact_dir: attempt_dir, fence: fence,
  limits: %{pending_frames: 16, pending_bytes: 262_144, checkpoint_ms: 250}
)
{:ok, accepted} = MedEx.StreamWriter.push(writer, frame)
{:ok, durable} = MedEx.StreamWriter.checkpoint(writer)
{:ok, index} = MedEx.StreamWriter.finish(writer)
index_digest = MedEx.Serialization.digest(index)
```

Mutating calls require the bound PID. `push/3` also accepts the expected fence.
Receipts name the stream, source epoch, descriptor, fence, journal ID, generation
and digest. `accepted_sequence`, `accepted_sample`, `durable_sequence` and
`durable_sample` are exclusive next positions. Spool deletion uses only the
durable boundary of the active authenticated attempt. The writer issues
`{:med_ex_durable, writer, receipt}` to its owner on idle timer checkpoints and
`{:med_ex_storage_failed, writer, reason}` on a failed timer flush.

`StreamWriter.stats/1` returns current/peak pending frames and bytes, committed
raw byte and frame counts, span count, current journal bytes and effective limits.
The default per-stream sample duration cap is 1,800 seconds and the native-byte
budget is 512 MiB. A host must enforce its aggregate acquisition budget across
streams and metadata. On a capacity stop, the owner receives an interrupted
index if the final flush/seal succeeds.

The owner uses synchronous calls on one writer per stream and grants bounded
credits upstream. A chunk rotates at the byte/frame threshold, timer, configuration
change, gap or terminal operation. It never contains interpolated samples.
Matching older frame identities return the current receipt. Future frames return
`{:error, {:replay, next_sequence, next_sample}}`. Conflicting duplicates stop
admission and attempt to seal the failed stream. A validated gap has this shape:

```elixir
%{id: gap_id, irreversible: true, first_sequence: expected_seq, next_sequence: resumed_seq,
  span: %MedEx.IntegritySpan{stream_id: stream_id, source_epoch: source_epoch,
    code: :source_gap, first_sample: expected_sample, end_sample: resumed_sample,
    source: "gateway", context: %{"cause" => reason}}}
```

`record_gap/2` commits the preceding data and gap before returning. Unknown
loss extent uses `interrupt/2`; only a known terminal input calls `finish/1`.
The sealed index preserves ordered chunks, explicit gaps, interpretation spans,
the terminal reason, current fence and predecessor cutoff. Both terminal calls
stop the worker. Legacy continuous WAV `Capture.finish/1` keeps its own contract.

## Durable storage

Use a host-owned, trusted, local POSIX directory with exclusive creation, hard
links, per-file sync and directory sync. Each attempt has an exclusive journal
and new directory. Content-addressed `.pcm` objects are synced, installed by
hard link and directory-synced before the corresponding journal record is
appended and synced. Immutable existing keys must match size and digest.
Each journal record binds generation, previous digest and exact canonical MEJ1
payload; a separate header checksum protects the bounded length against torn-tail
misclassification. Total envelope size is at most 64 KiB. Record count is bounded
at 100,000. Raw chunk reads verify their byte size and SHA-256. An unreferenced
object or `.part` never grants coverage.

The host persists a new fence before opening its writer. It revokes ingress and
confirms prior writer termination before replacement. This adapter additionally
excludes concurrent recovery/import within the same BEAM. Local locks cannot
quiesce another OS process. The host must gate cross-process access.

```elixir
{:ok, recovery} = MedEx.Storage.File.recover(old_dir,
  stream: spec, fence: old_fence, known_receipt: last_durable_or_accepted_receipt)
# The receipt passed back by recovery covers the latest verified frozen prefix.
predecessor = %{artifact_dir: old_dir, receipt: recovery.receipt}
{:ok, successor} = MedEx.StreamWriter.start_link(
  owner: self(), stream: spec, artifact_dir: new_dir, fence: new_fence, predecessor: predecessor)
```

Recovery checks the identity, bounded journal chain, exact frame fingerprints,
object bytes, continuity/gaps and the durable portion of every supplied receipt.
Pass the latest known host/producer acknowledgement. Use the **latest verified
post-quiescence receipt** as the import cutoff, even if the client's durable ACK
was older. Import refuses a newer committed predecessor generation, a finished or
failed predecessor, a live predecessor and an unverified cutoff. It preserves
the old journal unchanged, copies its verified prefix into a new immutable object
and installs links to verified immutable source chunks in the successor. Current
receipts then name the new journal and fence. Both directories must be on the
same supported filesystem. The maximum frozen lineage depth is 32.

`recover/2` returns the derived index, receipt, `torn_tail`, `terminal_recorded`,
`sealed` and the installed index digest (or nil). A missing terminal derives an
interrupted index with unknown tail. A valid terminal with missing final index
can be reconciled with `reconcile_index/2` under confirmed quiescence. A
trailing incomplete record is ignored after preserving the original bytes. An
interior checksum failure, wrong index, missing chunk or previously acknowledged
generation outside the verified prefix blocks recovery.

The ordinary call deadline is 5 seconds, terminal drain 20 seconds, open/recovery
30 seconds. Optional terminal/checkpoint/receipt/gap timeout arguments are in
milliseconds. The fourth argument to `push/4` sets its deadline. Recovery accepts
`timeout:`. A timeout yields an unknown outcome, and the OS write can finish
later. Revoke ingress, confirm quiescence, then reconcile. The 250 ms trigger is
a batching target and cannot bound fsync latency.

## Clock, control and sparse values

`ClockAlign.fit/2` intersects four-timestamp constraints with qualified positive
rate bounds. `interval/3` maps a sample anchor and index to an outward-rounded
host-monotonic interval or an explicit unavailable reason. Keep the source and
host generations, raw probes, policy, estimate, acquisition path error and
validity window with any reviewed alignment. `ControlInterlock.request/3` first
returns a persist intent; only a matching `:intent_committed` transition permits
dispatch. An ambiguous result retains historical uncertainty and blocks further
dependent mutation. The device's durable command identity lookup precedes its
expected-epoch check.

`MeasurementEvent` retains decimal mantissa/exponent, missing reasons, raw
bytes/digest, device time/status and provenance. `StatusEvent` records independently
sequenced technical events and observed intervals. Source facts and review
eligibility are distinct. No receipt timestamp establishes acquisition time.
