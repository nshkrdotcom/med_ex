# `MedRTC.Preview`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/med_ex-v0.1.0/lib/med_rtc/preview.ex#L1)

One replaceable, send-only WebRTC peer for an Opus preview. The caller owns
the peer and receives its ExWebRTC state changes. Capture has its own lifetime.

# `t`

```elixir
@type t() :: %MedRTC.Preview{pid: pid(), track_id: ExWebRTC.MediaStreamTrack.id()}
```

# `answer`

```elixir
@spec answer(String.t()) :: {:ok, t(), String.t()} | {:error, term()}
```

Answers a receive-only audio offer containing the browser's ICE candidates.

# `close`

```elixir
@spec close(t()) :: :ok
```

# `send_opus`

```elixir
@spec send_opus(t(), binary(), non_neg_integer()) :: :ok
```

Sends one 20 ms Opus frame. Frame indices are relative to the acquisition.

# `send_opus`

Sends one Opus frame using separate packet and media indices.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
