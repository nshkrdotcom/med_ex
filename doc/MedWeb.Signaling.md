# `MedWeb.Signaling`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/v0.1.0/lib/med_web/signaling.ex#L1)

Browser signaling message normalization and reconnect handshake contract for
MedEx live sessions.

# `client_signal`

```elixir
@type client_signal() ::
  {:join, String.t(), String.t(), atom(), non_neg_integer()}
  | {:leave, String.t(), String.t(), non_neg_integer()}
```

# `hook_asset_full_path`

```elixir
@spec hook_asset_full_path() :: String.t()
```

Resolves the absolute path to the shipped browser hook asset whether loaded
from `:med_web` in source mode or from the Welded `:med_ex` SDK package.

# `hook_asset_path`

```elixir
@spec hook_asset_path() :: String.t()
```

Returns the shipped browser hook asset relative path inside `priv/`.

# `to_session_event`

```elixir
@spec to_session_event(client_signal()) :: MedCore.Session.event()
```

Normalizes a browser signaling event into a pure `MedCore.Session` event.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
