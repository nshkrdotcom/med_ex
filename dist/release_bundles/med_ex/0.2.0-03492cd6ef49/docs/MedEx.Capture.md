# `MedEx.Capture`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/med_ex-v0.2.0/lib/med_ex/capture.ex#L1)

GenServer that writes indexed mono 48 kHz PCM16LE audio to an immutable,
content-addressed WAV file and fans full frames out to a bounded live Opus
preview branch.

## Lifecycle & Ownership

The host starts each capture under its own `DynamicSupervisor` (this module
uses `restart: :temporary` and registers no global names). Capture monitors
the `:owner` producer process and stops, removing its temporary `.part` file,
if `:owner` exits before `finish/1` succeeds. Only this PID may call
`push/3` and `finish/1`. Other callers receive `{:error, :not_owner}`.

## Preview Messages

A preview peer owner calls `subscribe/1` (single active subscriber; a newer
subscriber replaces the previous one) and receives:

  * `{:med_ex_preview, capture_pid, sample_index, opus_payload}` — one
    encoded 20 ms Opus packet. After sending it with `MedEx.Preview.send_opus/4`,
    call `demand/1` to request the next packet.
  * `{:med_ex_preview_replaced, capture_pid}` — sent to the displaced listener
    when a different process subscribes.
  * `{:med_ex_preview_failed, capture_pid, reason}` — sent if the internal
    Opus encoder exits. Capture itself continues uninterrupted and a new
    subscriber can re-subscribe.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `demand`

```elixir
@spec demand(GenServer.server()) :: :ok
```

Signals readiness for the next `{:med_ex_preview, ...}` packet from the
active preview subscriber.

# `finish`

```elixir
@spec finish(GenServer.server()) :: {:ok, MedEx.Evidence.t()} | {:error, term()}
```

Flushes and fsyncs the WAV header, installs the content-addressed
`<file_sha256>.wav` file, fsyncs `:artifact_dir`, and stops the capture.

Returns `{:ok, %MedEx.Evidence{}}`, `{:error, :empty_capture}` if no samples
were pushed, `{:error, :artifact_conflict}` if a conflicting file already
exists at the target digest path, or `{:error, reason}` on filesystem failure.

# `push`

```elixir
@spec push(GenServer.server(), non_neg_integer(), binary()) :: :ok | {:error, term()}
```

Appends one contiguous mono 48 kHz PCM16LE chunk at `first_sample`.

Chunks must start at sample `0`, advance contiguously without gaps, contain
an even number of bytes in `2..1920` (up to 960 samples / 20 ms), stay within
the 30-minute maximum (`86_400_000` samples), and send at most one short tail
frame (`< 1920` bytes) immediately before `finish/1`.

A non-owner receives `{:error, :not_owner}` and recording continues.
For the producer, returns `:ok`, or `{:error, :invalid_frame | File.posix()}` (stopping the
capture process and discarding the temporary file).

# `start_link`

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
```

Starts a capture process linked to the caller (typically a host `DynamicSupervisor`).

## Required options

  * `:owner` — PID of the single PCM producer process. Capture monitors this
    PID and aborts if it exits before `finish/1`.
  * `:acquisition_id` — host-assigned string identifying this acquisition.
  * `:artifact_dir` — existing directory where the temporary `.part` file and
    final `<file_sha256>.wav` artifact are written.

# `subscribe`

```elixir
@spec subscribe(GenServer.server()) :: :ok | {:error, :preview_unavailable}
```

Subscribes the calling process to bounded live Opus preview frames.

Only one preview subscriber is active at a time. A new subscriber replaces
the previous one. Returns `:ok` when the encoder is ready or
`{:error, :preview_unavailable}` if startup fails or is cancelled. Capture
allows five seconds for startup. The caller also cancels its subscription if
Capture has not replied within six seconds. Recording continues during startup.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
