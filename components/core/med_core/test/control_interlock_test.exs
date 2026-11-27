defmodule MedEx.ControlInterlockTest do
  use ExUnit.Case, async: true
  alias MedEx.ControlInterlock, as: C

  defp command,
    do: %{
      id: "command",
      fingerprint: String.duplicate("a", 64),
      boot_id: "boot",
      target: "monitor",
      generation: 2,
      expected_epoch: 0,
      value: 2,
      expired: false
    }

  defp state, do: %C{target: "monitor", boot_id: "boot", generation: 2, current_epoch: 0}

  defp applied,
    do:
      Map.take(command(), [:id, :fingerprint, :boot_id, :target, :generation])
      |> Map.merge(%{
        outcome: :applied,
        epoch: 1,
        application: %{observed_at: 100, first_sample: 960}
      })

  test "exact persisted historical application can settle unknown; current setting cannot" do
    assert {:ok, s, [_]} = C.request(state(), command(), %{raw_sample: 1920})
    assert {:ok, s, [_]} = C.step(s, {:intent_committed, "command"})
    assert {:ok, s, _} = C.step(s, {:timeout, "command"})

    assert {:ok, same, [_]} =
             C.step(s, {:actual_state, "monitor", "boot", 1, %{observed_at: 200}})

    assert same.pending.phase == :outcome_unknown

    for {key, value} <- [
          id: "other",
          fingerprint: String.duplicate("b", 64),
          boot_id: "other",
          target: "raw",
          generation: 1,
          epoch: 2
        ] do
      assert {:error, :conflicting_result} =
               C.step(s, {:historical_result, Map.put(applied(), key, value)})
    end

    assert {:ok, settled, [{:persist_applied, result}]} =
             C.step(s, {:historical_result, applied()})

    assert result.application.first_sample == 960
    assert settled.current_epoch == 1 and settled.pending == nil
    assert length(settled.historical_unknown) == 1
  end

  test "expiry, freeze and malformed authority cannot start or rewrite application" do
    assert {:error, :expired} = C.request(state(), %{command() | expired: true}, %{})
    assert {:error, :stale_generation} = C.request(state(), %{command() | generation: 3}, %{})
    assert {:error, :invalid_command} = C.request(state(), Map.delete(command(), :target), %{})
    {:ok, s, _} = C.request(state(), command(), %{})
    {:ok, s, _} = C.step(s, :freeze)
    assert {:error, :frozen} = C.step(s, {:historical_result, applied()})
  end

  test "device cache binds exact command identity and remains historical across expiry" do
    cmd = command()

    cache = %{
      cmd.id => %{
        fingerprint: cmd.fingerprint,
        command: Map.delete(cmd, :expired),
        result: applied()
      }
    }

    assert {:cached, _} = C.device_decide(cache, %{cmd | expired: true}, 1)
    assert {:error, :command_id_conflict} = C.device_decide(cache, %{cmd | generation: 3}, 1)
    assert {:error, :expired} = C.device_decide(%{}, %{cmd | expired: true}, 0)
    assert {:execute_and_persist_result, ^cmd} = C.device_decide(%{}, cmd, 0)

    for ledger <- [nil, [], 2, "bad"],
        do: assert({:error, :invalid_command} = C.device_decide(ledger, cmd, 0))
  end

  test "reported unknown and reboot preserve one exact historical fact without duplicate growth" do
    {:ok, requested, _} = C.request(state(), command(), %{raw_sample: 1920})
    {:ok, dispatched, _} = C.step(requested, {:intent_committed, "command"})
    unknown = applied() |> Map.drop([:epoch, :application]) |> Map.put(:outcome, :outcome_unknown)
    assert {:ok, uncertain, _} = C.step(dispatched, {:historical_result, unknown})

    assert [%{command: %{id: "command"}, from: %{raw_sample: 1920}, until: :unknown}] =
             uncertain.historical_unknown

    assert {:ok, repeated, _} = C.step(uncertain, {:historical_result, unknown})
    assert repeated.historical_unknown == uncertain.historical_unknown
    assert {:ok, rebooted, _} = C.step(repeated, {:boot_changed, "next_boot", 0})
    assert rebooted.pending == nil and rebooted.historical_unknown == uncertain.historical_unknown
  end

  test "history and device-ledger bounds refuse new commands without losing previous facts" do
    full = %{state() | historical_unknown: List.duplicate(%{historical: :unknown}, 256)}
    assert {:error, :command_limit} = C.request(full, command(), %{})
    ledger = Map.new(1..256, &{"old_#{&1}", %{}})
    assert {:error, :command_limit} = C.device_decide(ledger, command(), 0)
  end
end
