# `MedRTC.SessionServer`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/v0.1.0/lib/med_rtc/session_server.ex#L1)

OTP `GenServer` owning a live `%MedCore.Session{}` and dispatching emitted
producer facts to registered subscribers.

# `start_opt`

```elixir
@type start_opt() ::
  {:session, MedCore.Session.t()}
  | {:subscribers, [pid()]}
  | {:name, GenServer.name()}
```

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `dispatch`

```elixir
@spec dispatch(GenServer.server(), MedCore.Session.event()) ::
  {MedCore.Session.t(), [MedCore.Session.effect()]}
```

# `snapshot`

```elixir
@spec snapshot(GenServer.server()) :: MedCore.Session.t()
```

# `start_link`

```elixir
@spec start_link([start_opt()]) :: GenServer.on_start()
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
