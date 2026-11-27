# Host integration and root ownership

A host must authorize source identity and reserve the attempt/fence before any
writable filesystem effect. Keep one authoritative owner of each stream. The
SDK does not authenticate a patient/device, manage an encounter, or choose a
backend. Use the concrete File implementation.

## Exclusive root contract

Hold a real OS root lock for the full writer/recovery lifetime. The supplied
`root_owner` PID must answer
`{:med_ex_root_ownership, absolute_artifact_dir}` with
`{:ok, %{root: absolute_root, token: stable_reference}}` only while its original
lock is live and the requested path is inside the owned service root. The SDK
checks this proof and trusted paths before effects. Fail-stop on lock loss;
never reacquire a new token around surviving workers. `tools/cli_recorder.exs`
shows the standalone Linux flock host. Fabric supplies its capture root owner.

## Consequential operations

```elixir
{:ok, writer} = MedEx.StreamWriter.start_link(
  owner: self(), fence: fence, stream: descriptor,
  artifact_dir: attempt_dir, root_owner: root_owner,
  limits: %{checkpoint_ms: :manual})
{:ok, accepted} = MedEx.StreamWriter.push(writer, fence, frame, 5_000)
{:ok, durable} = MedEx.StreamWriter.checkpoint(writer, fence, 5_000)
true = MedEx.Receipt.durable?(durable)
{:ok, terminal} = MedEx.StreamWriter.finish(writer, fence, 5_000)
```

In a database host, acquire the per-stream effect gate before the SQL scope;
recheck authority and keep the SQL lock across the admitted effect and durable
projection. Return an ACK only after commit and a current-binding check. A DB
backend failure may release SQL locks while an already admitted OS write
continues. Retire, retain the effect gate, and prove actual worker/handle/lock
quiescence before recovery, successor open or final promotion. Do not flush
accepted-only backlog under stale authority.

A committed ACK can arrive after authority changes. It proves a historical fact,
never permission to write again. Match connection incarnation and full binding;
a locally invalidated/superseded connection must not advance credit or reclaim.

Use typed read-only recovery for journal truth. An absent terminal index is
explicit; only separately authorized quiesced settlement calls
`Storage.File.reconcile_terminal/2`. Known noncommit and outcome unknown have
different retry rules. Do not manufacture a receipt from database coordinates.
