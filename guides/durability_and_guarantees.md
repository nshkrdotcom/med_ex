# Durability and Ordering Guarantees

This page states the exact durability, fencing, and recovery guarantees of
`MedEx.StreamWriter` and `MedEx.Storage.File`, and links each guarantee to the
test that exercises it.

## 1. Durable Prefix and Checkpointing

- **Periodic checkpoints (`checkpoint_ms: pos_integer()`):** Frames accepted by
  `push/2` or `push/3` are buffered until the batch limit or checkpoint timer fires.
  A frame is durable only after `checkpoint/1` or `finish/1` returns `{:ok, receipt}`
  (or a periodic flush commits it to `stream.mejournal`).
- **Host-fenced manual checkpoints (`checkpoint_ms: :manual`):** The writer never
  flushes on a timer and never flushes volatile frames on owner loss. The host
  owns every durable boundary via explicit `checkpoint/1` and `finish/1` calls.
  *(Proved by `core/med_capture/test/stream_writer_test.exs` and
  `core/med_capture/test/host_integration_test.exs`.)*

## 2. Fencing and Single-Owner Mutation

- `StreamWriter` registers no global name, monitors its `:owner` PID, and rejects
  mutating calls from any other PID (`{:error, :not_owner}`).
- Fenced `push/3` calls must carry the writer's active `:fence` token; mismatched
  fences are rejected without mutating state.
- On owner exit, the writer terminates cleanly (`restart: :temporary`), leaving
  only previously committed batches in the durable prefix.
  *(Proved by `core/med_capture/test/host_integration_test.exs`.)*

## 3. Crash-Point Recovery (`MedEx.Storage.File.recover/2`)

`Storage.File` persists content-addressed `.pcm` chunks and a hash-chained
`stream.mejournal` with an index:

- **Orphan chunk before journal append:** A `.pcm` chunk written without a
  corresponding journal entry is ignored on recovery; the durable prefix ends at
  the last committed journal entry.
- **Truncated or corrupt journal tail:** Recovery detects corrupt/incomplete
  trailing bytes and refuses silent acceptance.
- **Sealed stream immutability:** Once `finish/2` seals a stream, further writes
  are rejected and recovery reports the sealed status and final receipt.
- **Descriptor identity verification:** Opening a writer against an existing
  stream verifies descriptor identity before accepting writes.
  *(Proved by `core/med_capture/test/storage_contract_test.exs` and
  `core/med_capture/test/storage_conformance_test.exs`.)*

## 4. Ordering and Wire Invariants (`core/med_core`)

- `StreamCursor.plan/2` enforces strictly increasing sequence numbers and
  contiguous sample coordinates, emitting explicit `{:gap, _}`, `{:reconcile, _}`,
  or `{:replay, _}` intents rather than silently dropping or reordering frames.
- `Wire.FrameV1` (`MEX1`) and `CanonicalJSON` (`MEJ1`) round-trip losslessly;
  `Wire.Control` rejects duplicate JSON keys.
- `ClockAlign` preserves exact rational affine bounds without floating-point drift.
  *(Proved by `core/med_core/test/frame_properties_test.exs` and
  `core/med_core/test/core_properties_test.exs`.)*

## 5. Filesystem Assumptions

- **Tested:** Local POSIX filesystem (`ext4` on Linux) with `fsync` semantics for
  file data and parent directory entries.
- **Untested:** NFS, SMB/CIFS, FUSE overlays, and Windows filesystems. Do not
  assume atomic rename or durability guarantees on network filesystems without
  separate qualification.
