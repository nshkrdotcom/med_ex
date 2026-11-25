defmodule MedEx.ControlInterlockTest do
  use ExUnit.Case, async: true
  alias MedEx.ControlInterlock, as: C

  test "dispatch follows durable intent and timeout preserves unknown outcome" do
    state = %C{target: "monitor", boot_id: "b1", current_epoch: 3}
    cmd = %{id: "c1", fingerprint: "digest1", boot_id: "b1", expected_epoch: 3, value: :half}

    assert {:ok, requested, [{:persist_intent, ^cmd, %{audio: 960}}]} =
             C.request(state, cmd, %{audio: 960})

    assert {:error, :unexpected_event} = C.step(requested, {:timeout, "c1"})
    assert {:ok, sent, [{:dispatch, ^cmd}]} = C.step(requested, {:intent_committed, "c1"})
    assert {:ok, unknown, effects} = C.step(sent, {:timeout, "c1"})
    assert unknown.pending.phase == :outcome_unknown
    assert {:query_actual_state, "monitor"} in effects
    assert {:error, :mutation_in_flight} = C.request(unknown, cmd, %{})
    assert {:ok, applied, _} = C.step(unknown, {:applied, "c1", "digest1", "b1", 4, :unknown})
    assert applied.current_epoch == 4
    assert [%{until: :unknown}] = applied.historical_unknown
  end

  test "device replay returns saved result despite now-stale expected epoch" do
    cmd = %{id: "c1", fingerprint: "d", expected_epoch: 3}
    ledger = %{"c1" => %{fingerprint: "d", result: {:applied, 4}}}
    assert {:cached, {:applied, 4}} = C.device_decide(ledger, cmd, 4)

    assert {:error, :command_id_conflict} =
             C.device_decide(ledger, %{cmd | fingerprint: "changed"}, 4)

    assert {:error, :stale_configuration} = C.device_decide(%{}, cmd, 4)
  end

  test "current state and reboot do not assign a historical source boundary" do
    s = %C{target: "preview_filter", boot_id: "b", current_epoch: 0}

    cmd = %{
      id: "c",
      fingerprint: "fp",
      boot_id: "b",
      expected_epoch: 0,
      value: "flat",
      target: "preview_filter"
    }

    assert {:error, :wrong_target} = C.request(s, %{cmd | target: "sensor_gain"}, %{})
    {:ok, requested, _} = C.request(s, cmd, %{"audio" => 960})
    {:ok, sent, _} = C.step(requested, {:intent_committed, "c"})
    {:ok, ambiguous, _} = C.step(sent, {:timeout, "c"})

    assert {:error, :conflicting_result} =
             C.step(ambiguous, {:actual_state, "preview_filter", "new_boot", 1, "flat"})

    assert {:ok, observed, _} =
             C.step(ambiguous, {:actual_state, "preview_filter", "b", 1, "flat"})

    assert [%{until: :unknown, from: %{"audio" => 960}}] = observed.historical_unknown
    assert observed.current_epoch == 1
    assert {:ok, rebooted, _} = C.step(sent, {:boot_changed, "next_boot", 0})
    assert {:error, :wrong_boot} = C.request(rebooted, cmd, %{})
  end
end
