# Streams, Storage, Clock, and Control

This guide covers the revision-1 (`MedEx.Contract.api_revision() == 1`) data contracts, framing formats, durable stream recorder, crash recovery, rational clock alignment, and technical command interlocks in `:med_ex`.

## 1. Stream Descriptors, Modalities, And Provenance

Every regular waveform stream begins with an immutable `%MedEx.StreamSpec{}`:

- **Identity and epoch:** `acquisition_id`, `source_ref` (authenticated device/gateway identity), `boot_id` (source boot session), `stream_id`, and `source_epoch` (`0..0xFFFFFFFF`). Rebooting a source or changing descriptor parameters starts a new `boot_id` / `source_epoch`—never mutate an active descriptor in place.
- **Modality, encoding, and rate:** Namespaced `modality` (for example `"cardiac:ecg"` or `"acoustic:stethoscope"`), interleaved signed little-endian integer `encoding` (`:s16le`, `:s24le`, or `:s32le`), and exact rational `sample_rate` (`{numerator, denominator}`, such as `{4_000, 1}` or `{500, 1}`).
- **Channels and honest calibration:** Ordered synchronous `channels` (`1..32` unique channel IDs). Each channel declares `unit` (`:unknown` or unit string) and `calibration` (`:unknown` or `%{zero: integer, scale_num: nonzero_int, scale_den: pos_int, reference: id}`). Unknown calibration remains `:unknown`—`MedEx` never fabricates a `1.0` physical scale. Asynchronous sensors belong in separate streams rather than interleaved channels.
- **Clock and processing provenance:** Optional `clock` descriptor (`%{domain_id, boot_id, generation, tick_rate, uncertainty_ticks}` or `:unknown`), `source_processing` (`:unknown` or up to 32 `%{name, origin: :observed | :claimed, value}` facts), and `capabilities` (`encodings`, `max_frame_samples`, `max_payload_bytes` up to `65_536`, `replay: :none | :durable_spool`, and `commands`).
- **Self-identifying `descriptor_ref`:** Compute the canonical SHA-256 digest over the descriptor map (excluding `"descriptor_ref"`) with `MedEx.Serialization.descriptor_ref/1`, store it on the struct, validate with `MedEx.StreamSpec.validate/1`, and persist both the serialized descriptor (`MedEx.Serialization.to_map/1`) and `descriptor_ref` in the host's admission store. Reconstruct with `MedEx.Serialization.stream_spec/1`.

## 2. Wire Framing And Semantic Identity

`MedEx` separates wire transport parsing from authenticated stream admission:

- **Binary waveform frames (`MedEx.Wire.FrameV1`):** Encodes and decodes the 48-byte big-endian `MEX1` v1 header (`"MEX1"`, version `1`, flags `0`, header size `48`, `stream_number`, `source_epoch`, `config_epoch` with `0xFFFFFFFF` encoding `:unknown`, 64-bit `sequence`, 64-bit `first_sample`, 32-bit `sample_count`, 32-bit `payload` length up to `65_536` bytes, 32-bit reserved `0`, followed by native interleaved sample bytes).
- **Bounded JSON control messages (`MedEx.Wire.Control`):** Encodes and decodes `schema: "medex.device.v1"` messages up to `16_384` bytes against a caller-supplied allowlist of `type` strings, rejecting duplicate JSON keys at every nesting depth (`{:error, :duplicate_key}`) and parsing exact decimal `uint64/1` strings.
- **Admitted `%MedEx.SampleFrame{}` and `MedEx.FrameFingerprint`:** A decoded `MEX1` frame is **not** yet admitted evidence. The host first authenticates the connection, maps `stream_number` to the reserved `%MedEx.StreamSpec{}`, constructs `%MedEx.SampleFrame{}`, and validates stride and bounds via `MedEx.SampleFrame.validate/2`. `MedEx.FrameFingerprint.of/1` computes the transport-independent semantic digest (`SHA-256("medex.frame.v1\0" <> canonical_json)`); hosts may record raw wire SHA-256 alongside it as a separate transport observation.

## 3. Sparse Measurements And Device Status

Non-waveform device outputs use dedicated contracts rather than synthetic single-sample waveforms:

- **`MedEx.MeasurementEvent`:** Represents discrete or spot-check measurements (such as pulse oximetry, blood pressure, or temperature) with `event_id`, `acquisition_id`, `source_ref`, `boot_id`, `stream_id`, `source_epoch`, `gateway_sequence`, `descriptor_ref`, optional `source_record_id`, `metrics` (`1..32` entries of `{:value, mantissa, exponent, unit}` with `exponent in -18..18` or `{:missing, reason}`), `raw` (`{:bytes, binary}` up to 16 KiB or `{:sha256, digest}`), `device_status`, `device_time`, `receipt_time`, and `provenance` facts. Serialize and restore without binary floating-point rounding via `MedEx.Serialization.to_map/1` and `MedEx.Serialization.measurement/1`. Importantly, `receipt_time` never substitutes for an `:unknown` `device_time`.
- **`MedEx.StatusEvent`:** Records technical device or gateway observations (`code`, `sequence`, `observed_interval` as `:unknown` or `%{clock_id, earliest, latest}`, optional `source_alarm_id`, `state`, and `acknowledgement`). Status sequence numbers and alarm IDs are independent of waveform sample coordinates.
- **`MedEx.IntegritySpan`:** Attaches structured technical qualifiers (`:source_gap`, `:clock_unavailable`, `:configuration_unknown`, `:device_status_invalid`, `:source_processing_unverified`, `:duplicate_conflict`) to either a half-open sample range (`first_sample..end_sample`) or a non-empty list of `event_ids`.

## 4. Authoritative Lossless Capture, Receipts, Replay, And Gaps

Start one `MedEx.StreamWriter` per active authenticated stream attempt:

```elixir
{:ok, writer} =
  MedEx.StreamWriter.start_link(
    owner: self(),
    stream: spec,
    artifact_dir: attempt_dir,
    fence: fence,
    limits: %{pending_frames: 16, pending_bytes: 262_144, checkpoint_ms: 250}
  )

{:ok, accepted} = MedEx.StreamWriter.push(writer, fence, frame)
{:ok, durable} = MedEx.StreamWriter.checkpoint(writer)
{:ok, index} = MedEx.StreamWriter.finish(writer)
index_digest = MedEx.Serialization.digest(index)
```

### Ownership, Receipts, And Upstream Spool Truncation

- **Caller and fence enforcement:** Every `StreamWriter` call requires the bound `:owner` PID (`{:error, :not_owner}` otherwise). `push/3` and `push/4` also verify the active `fence` token (`{:error, :stale_fence}` on mismatch).
- **Volatile versus durable positions:** Push replies return a receipt containing `stream_id`, `source_epoch`, `descriptor_ref`, `fence`, `journal_id`, `journal_generation`, `journal_digest`, volatile `accepted_sequence` / `accepted_sample`, and journal-synced `durable_sequence` / `durable_sample` (all exclusive next cursors).
- **Batching and async durability notifications:** Frames accumulate in memory up to `pending_frames` (default `16`), `pending_bytes` (default `262_144`), a `config_epoch` change, or `checkpoint_ms` (default `250` ms). When an idle timer flushes a chunk, the owner receives `{:med_ex_durable, writer, receipt}` (or `{:med_ex_storage_failed, writer, reason}` if disk sync fails). **Upstream device spools must delete retained frames only up to `durable_sequence` / `durable_sample` of the active authenticated attempt.**

### Replay, Duplicate Conflicts, Explicit Gaps, And Termination

- **Idempotent replay:** Re-sending an already accepted or durable `sequence` whose `FrameFingerprint` matches returns `{:ok, current_receipt}`.
- **Out-of-order / future frames:** Frames ahead of `next_sequence` or `next_sample` return `{:error, {:replay, next_sequence, next_sample}}` without mutating state so the sender can rewind or record an explicit gap.
- **Conflicting duplicates:** Re-sending an existing `sequence` (or gap `id`) with different content immediately stops admission, attempts to seal the stream with `terminal: :failed` and `:duplicate_conflict`, and returns `{:error, :duplicate_conflict}` (or `{:error, {:outcome_unknown, reason}}` if sealing fails).
- **Explicit irreversible gaps (`record_gap/2`):** Missing samples are never filled by interpolation. Record known source drops explicitly:

```elixir
gap = %{
  id: "gap-001",
  irreversible: true,
  first_sequence: expected_seq,
  next_sequence: resumed_seq,
  span: %MedEx.IntegritySpan{
    stream_id: spec.stream_id,
    source_epoch: spec.source_epoch,
    code: :source_gap,
    first_sample: expected_sample,
    end_sample: resumed_sample,
    source: "gateway",
    context: %{"cause" => "radio_drop"}
  }
}

{:ok, durable_receipt} = MedEx.StreamWriter.record_gap(writer, gap)
```

`record_gap/2` flushes any buffered preceding frames, commits the gap to the journal, and returns the updated durable receipt (idempotently returning the current receipt if the exact `gap` is replayed).
- **Terminal states (`finish/1` vs `interrupt/2`) and capacity bounds:** Call `finish/1` only when the source confirms clean stream completion; use `interrupt(writer, reason)` when a link drops, the source reboots, or tail loss is unknown. Default per-stream caps are `duration_seconds: 1_800` (30 minutes), `artifact_bytes: 536_870_912` (512 MiB), `1_000_000` frames, and `100,000` journal/span records; hitting a cap seals an `:interrupted` index, sends `{:med_ex_interrupted, writer, index}` to `:owner`, and replies `{:error, {:capacity, reason}}`. Hosts enforce aggregate budgets across multiple streams.

## 5. POSIX Storage, Crash Recovery, And Predecessor Lineage

`MedEx.Storage.File` requires a trusted local POSIX filesystem supporting exclusive file creation, hard links, `fsync` on regular files, and directory `fsync`:

- **Crash-safe write ordering:** Each attempt receives its own fresh directory and exclusive `stream.mejournal`. Content-addressed `<sha256>.pcm` chunk files are written to temporary files, `fsync`ed, hard-linked to their final digest names, and directory-`fsync`ed *before* the corresponding `MEJ1` journal record (up to 64 KiB, protected by both a header length checksum and a chained SHA-256 record digest) is appended and `fsync`ed. Unreferenced `.pcm` or temporary files never grant coverage.
- **Fencing and quiescence:** `MedEx.Storage.File` uses a node-local `:global` lock to prevent concurrent writer/recovery access within one BEAM, but OS-level cross-process fencing belongs to the host (for example via `flock` and PostgreSQL generation leases). Before recovering or replacing a writer, revoke old ingress, persist a new `fence`, and confirm the prior writer has exited.
- **Recovery and predecessor import:**

```elixir
{:ok, recovery} =
  MedEx.Storage.File.recover(old_dir,
    stream: spec,
    fence: old_fence,
    known_receipt: last_known_receipt
  )

# Import the verified frozen prefix into a new fenced directory on the same filesystem:
predecessor = %{artifact_dir: old_dir, receipt: recovery.receipt}

{:ok, successor} =
  MedEx.StreamWriter.start_link(
    owner: self(),
    stream: spec,
    artifact_dir: new_dir,
    fence: new_fence,
    predecessor: predecessor
  )
```

`recover/2` verifies the journal identity, hash chain, `.pcm` byte lengths and SHA-256 digests, sample/sequence coverage, and any `known_receipt` durable boundary. It ignores a torn trailing journal record without modifying `old_dir` and returns `%{index, receipt, index_digest, torn_tail, sealed, terminal_recorded}`.
  - If `terminal_recorded` is `true` and `sealed` is `false` (crash between terminal journal sync and `.index.mej1` installation), call `MedEx.Storage.File.reconcile_index/2` under quiescence to finish installing `<sha256>.index.mej1`.
  - If the prior attempt was interrupted (`terminal_recorded == false`), pass `recovery.receipt` (the latest verified durable prefix) in `predecessor` when opening `successor`. `StreamWriter` hard-links verified `.pcm` chunks and copies the verified journal bytes into an immutable `<sha256>.prefix` object (supporting up to 32 predecessor generations).
- **Verified segment reads and call deadlines:** Read finalized chunks with `MedEx.Storage.File.read_segment(dir, segment_ref)`, which re-verifies exact byte count and SHA-256 on every read. Default deadlines are 5 s for ordinary calls, 20 s for `finish`/`interrupt`, and 30 s for `start_link`/`recover`/`reconcile_index`. Any call timeout returns `{:error, {:outcome_unknown, :timeout}}` because an in-flight kernel write may still complete; revoke ingress, confirm quiescence, and run `recover/2` before continuing.

## 6. Clock Uncertainty And Device-Control Interlocks

### Affine Rational Clock Alignment (`MedEx.ClockAlign`)

Device clocks drift relative to host monotonic clocks and across network jitter. `MedEx.ClockAlign` computes exact rational bounds (`affine_polytope_v1`) without floating-point rounding:

1. Collect four-timestamp round-trip probes (`%{generation, h1, d2, d3, h4}` in integer microseconds) and supply a qualified policy (`%{generation, a_min, a_max, epsilon_us, host_now_us, max_probe_age_us, valid_device_us: {low, high}, holdover_rate}`).
2. Call `MedEx.ClockAlign.fit(probes, policy)` to intersect up to the newest 64 valid probes into a convex rate/offset polygon, returning `{:ok, estimate}` or `{:unavailable, reason}` (`:no_probes`, `:stale_probe`, `:contradictory_probes`, `:generation_mismatch`, etc.).
3. Map a device timestamp (`at_device_time/2`) or a sample index anchored by `%{generation, sample_index, device_us, period_min_us, period_max_us, error_us}` (`interval/3`) to an outward-rounded `{earliest_host_us, latest_host_us}` interval—or `{:unavailable, :outside_validity}` when queried outside `valid_device_us`. Persist raw probes, anchors, policy, and resulting intervals with the acquisition manifest so cross-stream correspondence remains auditable.

### Technical Command Interlocks (`MedEx.ControlInterlock`)

When a host adjusts a technical device or monitor setting (such as gain or filter mode), `MedEx.ControlInterlock` prevents silent state desynchronization:

1. `ControlInterlock.request(state, command, stream_watermarks)` validates `boot_id`, `expected_epoch == state.current_epoch`, and single in-flight mutation, returning `{:ok, state, [{:persist_intent, command, watermarks}]}`.
2. Only after the host commits that intent durably does `ControlInterlock.step(state, {:intent_committed, id})` emit `[{:dispatch, command}]`.
3. On `{:applied, id, fingerprint, boot_id, next_epoch, boundary}`, the interlock advances `current_epoch`. On `{:timeout, id}` or `{:boot_changed, new_boot, epoch}`, it transitions the command to `:outcome_unknown`, records the ambiguous watermark span in `historical_unknown`, and emits `{:query_actual_state, target}`. A later `{:actual_state, target, boot, epoch, observed}` reconciles the *current* epoch while preserving `:historical_boundary_unknown`—because reading current state cannot establish when an unobserved transition occurred on the waveform timeline.
4. On the device side, `ControlInterlock.device_decide(ledger, command, actual_epoch)` checks the durable command ledger by `command.id` **before** checking `expected_epoch`, ensuring retried commands after a lost acknowledgement return `{:cached, result}` instead of a spurious `:stale_configuration` error.
