# `MedEx.Preview`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/med_ex-v0.2.0/lib/med_ex/preview.ex#L1)

One replaceable, send-only WebRTC peer for an Opus preview. The caller owns
the peer and receives its ExWebRTC state changes. Capture has its own lifetime.

# `t`

```elixir
@type t() :: %MedEx.Preview{pid: pid(), track_id: ExWebRTC.MediaStreamTrack.id()}
```

# `answer`

```elixir
@spec answer(String.t(), keyword()) :: {:ok, t(), String.t()} | {:error, term()}
```

Answers a receive-only browser audio offer containing the browser's ICE candidates.

The calling process owns the resulting `ExWebRTC.PeerConnection` and receives
`{:ex_webrtc, peer.pid, {:connection_state_change, state}}` messages (such as
`:connected`, `:failed`, and `:closed`). Call `close/1` on teardown.

## Options

  * `:ice_servers` — list of ICE server maps passed to `ExWebRTC.PeerConnection`
    (defaults to `[]` for direct local candidates).
  * `:ice_transport_policy` — `:all` (default) or `:relay`. For relay-only
    preview, supply TURN credentials and select relay on the browser too.

# `close`

```elixir
@spec close(t()) :: :ok
```

Stops the underlying WebRTC peer connection if it is still alive.

# `send_opus`

```elixir
@spec send_opus(t(), binary(), non_neg_integer(), non_neg_integer()) :: :ok
```

Sends one Opus RTP packet with separate per-peer `sequence` (wrapped mod
`65_536`) and 48 kHz media clock `sample_index` (wrapped mod `2^32`).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
