# `MedRTC.PeerLoopback`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/v0.1.0/lib/med_rtc/peer_loopback.ex#L1)

Minimal real `ExWebRTC.PeerConnection` SDP/ICE loopback harness used to
exercise live WebRTC negotiation, peer disconnect, and replacement connection
establishment against `MedRTC.SessionServer`.

# `negotiated_pair`

```elixir
@type negotiated_pair() :: %{
  connection_id: String.t(),
  offerer: pid(),
  answerer: pid(),
  offer_sdp: String.t(),
  answer_sdp: String.t()
}
```

# `close_pair`

```elixir
@spec close_pair(negotiated_pair()) :: :ok
```

Closes both `ExWebRTC.PeerConnection` processes in a negotiated pair.

# `connect_pair`

```elixir
@spec connect_pair(String.t(), pos_integer()) ::
  {:ok, negotiated_pair()} | {:error, term()}
```

Starts two real `ExWebRTC.PeerConnection` instances with an `:audio`
transceiver, exchanges SDP offer/answer and ICE candidates, and waits until
both peers reach `:connected`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
