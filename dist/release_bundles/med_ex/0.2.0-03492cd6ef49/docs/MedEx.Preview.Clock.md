# `MedEx.Preview.Clock`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/med_ex-v0.2.0/lib/med_ex/preview/clock.ex#L1)

Tracks an unwrapped 48 kHz RTP media clock across captures for one preview peer.

Start with `nil`. Within a capture the clock follows the source sample index,
including gaps from dropped preview frames. The next capture starts one 20 ms
packet after the last tick sent to the peer.

# `t`

```elixir
@type t() :: %MedEx.Preview.Clock{
  capture: term(),
  index: non_neg_integer(),
  tick: non_neg_integer()
}
```

# `advance`

```elixir
@spec advance(t() | nil, term(), non_neg_integer()) :: t()
```

Advances the peer's clock for a delivered Opus packet.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
