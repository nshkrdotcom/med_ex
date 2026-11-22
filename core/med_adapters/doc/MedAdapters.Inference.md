# `MedAdapters.Inference`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/main/lib/med_adapters/inference.ex#L1)

Behaviour contract for advisory clinical inference adapters (e.g., Ortex/ONNX).

All inference outputs carry SaMD advisory metadata and the input window's
measured continuity so degraded or unverified windows are never surfaced clinically.

# `advisory_result`

```elixir
@type advisory_result() :: %{
  advisory_only: true,
  model_sha256: String.t(),
  signal_quality_score: float(),
  continuity: MedCore.Session.continuity_state(),
  payload: map()
}
```

# `infer`

```elixir
@callback infer(binary(), keyword()) :: {:ok, advisory_result()} | {:error, term()}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
