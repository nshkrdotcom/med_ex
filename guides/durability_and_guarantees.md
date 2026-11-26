# Durability and Ordering Guarantees

This page states the exact durability, fencing, and recovery guarantees of
`MedEx.StreamWriter` and `MedEx.Storage.File`, and links each guarantee to the
test that exercises it.

## 1. Durable Prefix and Checkpointing

- **Periodic checkpoints (`checkpoint_ms: pos_integer()`):** Frames accepted by
  `push/2` or `push/3` are buffered until the batch limit or checkpoint timer fires.
  A frame is durable only after `checkpoint/1` or `finish/1` returns `{:ok, receipt}`
  (or a periodic flush commits it to `stream.mejournal`).
- **Host-fenced manual checkpoints (`limits: %{checkpoint_ms: :manual}`):** The writer never
  flushes on a timer and never flushes volatile frames on owner loss. The host
  must hold its fence across every operation that can write: `push/3` can flush
  at frame/byte limits or a configuration change, and gap, checkpoint, finish,
  and interruption calls can also commit. Manual mode disables background
  commits; it does not make checkpoint and finish the only write boundaries.
  *(Proved by `stream_writer_test.exs`: "manual checkpoint mode disables timer
  flushes and commits only on explicit owner calls" and "manual writer owner exit
  leaves the durable prefix unchanged"; `host_integration_test.exs` exercises the
  same calls under a host `DynamicSupervisor`.)*

## 2. Fencing and Single-Owner Mutation

- `StreamWriter` registers no global name, monitors its `:owner` PID, and rejects
  mutating calls from any other PID (`{:error, :not_owner}`).
- Fenced `push/3` calls must carry the writer's active `:fence` token; a
  mismatched fence returns an error.
- On owner exit in manual mode, the writer terminates cleanly
  (`restart: :temporary`), leaving only previously committed batches in the
  durable prefix. Periodic mode instead attempts to flush pending frames and
  record an interruption; recover storage to determine the resulting prefix.
  *(Proved by `stream_writer_test.exs`: "owner, fence, accepted versus durable,
  exact replay and immutable final bytes" and the owner-exit test above;
  `host_integration_test.exs` checks `:not_owner` and wrong-fence rejection.)*

## 3. Crash-Point Recovery (`MedEx.Storage.File.recover/2`)

`Storage.File` persists content-addressed `.pcm` chunks and a hash-chained
`stream.mejournal` with an index:

- **Crash cuts:** a crash at any storage cut preserves the acknowledged prefix or
  recovers the complete uncertain append. *(`stream_writer_test.exs`: "storage
  crash cuts preserve the acknowledged prefix or recover the complete uncertain
  append".)*
- **Unknown tail:** incomplete bytes without a durable receipt remain unknown
  after a hard kill. *(`stream_writer_test.exs`: "incomplete bytes without any
  durable receipt remain unknown after hard kill".)*
- **Corruption:** a corrupt journal interior, a missing chunk or an overwritten
  chunk is rejected. *(`stream_writer_test.exs`: "rejects corrupt journal
  interior, missing and overwritten chunk".)* Trailing garbage after a sealed
  journal is also rejected. *(`storage_conformance_test.exs`.)*
- **Unreferenced chunk files:** an extra `.pcm` file with no journal entry does
  not change a sealed recovery. *(`storage_conformance_test.exs`.)*
- **Not covered by a dedicated test in this guide's pass:** writes after seal.
  Treat that behaviour as unspecified until a test is added.

## 4. Ordering and Wire Invariants (`core/med_core`)

- `StreamCursor.plan/2` returns explicit append, reconcile, gap and replay intents
  and is pure. *(`stream_cursor_test.exs`.)*
- `Wire.FrameV1` (`MEX1`) round-trips random payloads and coordinates;
  `CanonicalJSON` (`MEJ1`) sorts object keys at every nesting level and rejects numbers.
  *(`core_properties_test.exs`; fixed-seed random cases, not a property-testing
  library.)*
- `Wire.Control` rejects nested duplicate keys. *(`control_wire_test.exs`.)*
- `ClockAlign` bounds, holdover and generation checks. *(`clock_align_test.exs`.)*

## 5. Filesystem Assumptions

- **Tested:** Local POSIX filesystem (`ext4` on Linux) with `fsync` semantics for
  file data and parent directory entries.
- **Untested:** NFS, SMB/CIFS, FUSE overlays, and Windows filesystems. Do not
  assume atomic rename or durability guarantees on network filesystems without
  separate qualification.
