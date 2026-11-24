# `MedCore.Profile`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/v0.1.0/lib/med_core/profile.ex#L1)

Behaviour implemented by clinical product applications to compose MedEx
transport archetypes, streams, inference hooks, and device control policies.

# `inference_hook`

```elixir
@type inference_hook() :: {String.t(), module(), keyword()}
```

# `topology`

```elixir
@type topology() :: :server_terminated | :sfu | :hybrid
```

# `control_policy`

```elixir
@callback control_policy() :: module()
```

# `inference_hooks`

```elixir
@callback inference_hooks() :: [inference_hook()]
```

# `streams`

```elixir
@callback streams() :: [MedCore.StreamSpec.t()]
```

# `topology`

```elixir
@callback topology() :: topology()
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
