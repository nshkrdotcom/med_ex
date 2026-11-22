# `MedCore.StreamSpec`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/v0.1.0/lib/med_core/stream_spec.ex#L1)

Declarative contract for a clinical media, telemetry, or device control stream.

# `archetype`

```elixir
@type archetype() ::
  :diagnostic_audio | :telemetry | :control | :interactive_media | :voice_ai
```

# `integrity_policy`

```elixir
@type integrity_policy() :: %{
  require_dsp_disabled: boolean(),
  max_packet_loss_pct: float(),
  max_jitter_ms: non_neg_integer(),
  allow_plc: boolean(),
  sample_rate_hz: pos_integer()
}
```

# `t`

```elixir
@type t() :: %MedCore.StreamSpec{
  archetype: archetype(),
  codec_profile: term(),
  id: String.t(),
  integrity_policy: integrity_policy(),
  modality: atom(),
  priority: non_neg_integer()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
