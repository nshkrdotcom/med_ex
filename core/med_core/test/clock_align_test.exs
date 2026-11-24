defmodule MedEx.ClockAlignTest do
  use ExUnit.Case, async: true
  alias MedEx.ClockAlign

  test "an exact +180 ms offset rounds fractional timestamps outward" do
    assert {:ok, estimate} = ClockAlign.fit([probe(0, 180_000)], fixed_rate())
    assert {:ok, {180_000, 180_001}} = at(estimate, {1, 3})
    assert {:ok, {179_999, 180_000}} = at(estimate, {-1, 3})
  end

  test "negative host times use mathematical floor and ceiling" do
    assert {:ok, estimate} = ClockAlign.fit([probe(0, -180_000)], fixed_rate())
    assert {:ok, {-180_001, -180_000}} = at(estimate, {1, -3})
  end

  test "asymmetric paths and signed drift contain synthetic truth including holdout" do
    for ppm <- [35, -40] do
      truth = fn device_us ->
        div((1_000_000 + ppm) * device_us, 1_000_000) + 180_000
      end

      probes =
        for n <- 0..7 do
          receive_us = n * 2_000_000
          send_us = receive_us + 1_000_000

          %{
            generation: generation(),
            h1: truth.(receive_us) - 500 - n * 10,
            d2: receive_us,
            d3: send_us,
            h4: truth.(send_us) + 15_000 + n * 20
          }
        end

      assert {:ok, estimate} = ClockAlign.fit(probes, policy())

      for device_us <- [0, 3_000_000, 10_000_000, 16_000_000, 18_000_000] do
        assert {:ok, {earliest, latest}} = at(estimate, device_us)
        assert earliest <= truth.(device_us)
        assert latest >= truth.(device_us)
      end
    end
  end

  test "contradictory zero-delay observations have no feasible model" do
    assert {:unavailable, :contradictory_probes} =
             ClockAlign.fit([probe(0, 180_000), probe(0, 180_001)], fixed_rate())
  end

  test "timestamp uncertainty enlarges the feasible offset" do
    assert {:ok, estimate} =
             ClockAlign.fit([probe(0, 180_000)], Map.put(fixed_rate(), :epsilon_us, 2))

    assert {:ok, {179_998, 180_002}} = at(estimate, 0)
  end

  test "foreign generations and stale probes cannot create or reuse an estimate" do
    foreign = Map.put(probe(0, 180_000), :generation, {:host_a, :device_b})
    assert {:unavailable, :generation_mismatch} = ClockAlign.fit([foreign], fixed_rate())

    stale = Map.put(fixed_rate(), :max_probe_age_us, 1)
    assert {:unavailable, :stale_probe} = ClockAlign.fit([probe(0, 180_000)], stale)
    assert {:ok, estimate} = ClockAlign.fit([probe(0, 180_000)], fixed_rate())

    assert {:unavailable, :generation_mismatch} =
             ClockAlign.at_device_time(estimate, %{generation: foreign.generation, device_us: 0})
  end

  test "explicit holdover error widens bounds and the validity domain expires" do
    policy = Map.merge(fixed_rate(), %{holdover_rate: {1, 1_000}, valid_device_us: {0, 10_000}})
    assert {:ok, estimate} = ClockAlign.fit([probe(0, 180_000)], policy)
    assert {:ok, {180_999, 181_001}} = at(estimate, 1_000)
    assert {:ok, {189_990, 190_010}} = at(estimate, 10_000)
    assert {:unavailable, :outside_validity} = at(estimate, 10_001)
  end

  test "sample anchors propagate period and acquisition uncertainty in both directions" do
    assert {:ok, estimate} = ClockAlign.fit([probe(0, 180_000)], fixed_rate())

    anchor = %{
      generation: generation(),
      sample_index: 10,
      device_us: 100,
      period_min_us: {1, 3},
      period_max_us: {2, 3},
      error_us: {1, 10}
    }

    assert {:ok, {180_100, 180_101}} = ClockAlign.interval(estimate, anchor, 11)
    assert {:ok, {180_099, 180_100}} = ClockAlign.interval(estimate, anchor, 9)
    assert {:unavailable, :invalid_anchor} = ClockAlign.interval(estimate, %{}, 11)
  end

  test "only the most recent 64 observations constrain the result" do
    recent = for n <- 1..64, do: probe(n * 1_000_000, n * 1_000_000 + 180_000)
    probes = [probe(0, 181_000) | recent]
    assert {:ok, estimate} = ClockAlign.fit(probes, fixed_rate())
    assert length(estimate.probes) == 64
    assert {:ok, {64_180_000, 64_180_000}} = at(estimate, 64_000_000)
  end

  test "missing or nonpositive rate assumptions are unavailable" do
    assert {:unavailable, :no_probes} = ClockAlign.fit([], policy())
    assert {:unavailable, :invalid_policy} = ClockAlign.fit([probe(0, 0)], %{})

    assert {:unavailable, :invalid_policy} =
             ClockAlign.fit([probe(0, 0)], Map.put(policy(), :a_min, {0, 1}))
  end

  defp generation, do: {:host_a, :device_a}

  defp probe(device_us, host_us) do
    %{generation: generation(), h1: host_us, d2: device_us, d3: device_us, h4: host_us}
  end

  defp at(estimate, device_us) do
    ClockAlign.at_device_time(estimate, %{generation: generation(), device_us: device_us})
  end

  defp fixed_rate, do: Map.merge(policy(), %{a_min: {1, 1}, a_max: {1, 1}})

  defp policy do
    %{
      generation: generation(),
      a_min: {999_900, 1_000_000},
      a_max: {1_000_100, 1_000_000},
      epsilon_us: 0,
      host_now_us: 100_000_000,
      max_probe_age_us: 200_000_000,
      valid_device_us: {-1_000_000, 100_000_000},
      holdover_rate: {0, 1}
    }
  end
end
