# Streams, recording and verified playback

A descriptor fixes acquisition, source, boot/epoch, stream, channels, encoding,
rate, capabilities and canonical descriptor digest. SampleFrame validates raw
bytes against it. StreamCursor alone plans the next sample/sequence and explicit
gaps; identical fingerprints replay, conflicting duplicates refuse.

The sole writer API is start_link/1, push/4, record_gap/4, checkpoint/3, finish/3,
interrupt/4, receipt/3 and stats/3. Every operation has explicit fence and timeout.
The caller must be the bound owner. A typed Receipt distinguishes volatile
acceptance from fully durable progress. A Terminal holds verified index,
receipt and recovered state.

Manual host checkpoint mode prevents timer writes outside authorization scope.
Default standalone cadence is 250 ms, with 16 pending frames/262144 bytes,
30 minutes and 536870912 artifact bytes. Technical ceilings and terminal reserve
come from RecordingLimits. Admission stops before reserved terminal capacity;
physical ENOSPC can still make sealing unknown and must never produce a false
success. Keep raw/object, encoded journal and pending budgets distinct.

## Finalization

Stop source production; account for exact final coordinates and any partial tail.
Send the final short batch, checkpoint it before waiting for durable coverage,
then seal. No padding, silent discard or circular wait for finish versus ACK.
Owner death in host manual mode cannot authorize a late flush. After seal, writes,
gaps and checkpoints are refused. Exact terminal recovery is idempotent.

## Bounded reads

Recover/verify an acquisition as required, then bind a verified immutable index
to the promoted manifest, descriptor, fence and journal identity using
`Storage.File.read_verified_index/3`. Serve a requested coordinate with
`read_verified_segment/3`, which verifies the actual bounded bytes returned.
Changed provenance, unsafe paths/symlinks, wrong digest/length or missing data
refuse. Do not replay an entire journal for every segment.

`MedEx.Format.Wav.header(encoding, channels, integer_rate, byte_length)` creates
a validated playback header. It is a pure projection of a verified segment;
there is no separate WAV evidence model. Preserve gaps as segmented evidence.
