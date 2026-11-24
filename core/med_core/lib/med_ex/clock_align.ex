defmodule MedEx.ClockAlign do
  @moduledoc """
  Exact affine clock bounds from supplied rate and timestamp-error qualifications.

  Times are already normalized to microseconds. A rational is an integer or
  `{numerator, nonzero_denominator}`. Policy supplies positive `a_min/a_max`,
  combined timestamp/model `epsilon_us`, explicit host/device `generation`,
  `host_now_us`, `max_probe_age_us`, inclusive `valid_device_us`, and nonnegative
  `holdover_rate` (extra host microseconds per device microsecond outside the
  observed span). Zero holdover rate explicitly assumes no additional wander.

  These bounds/validity assumptions must come from caller qualification; this
  solver cannot establish them. Epsilon must already cover device timestamp
  error in host units. Probes contain `generation, h1, d2, d3, h4` with integer
  timestamps. Foreign, malformed or stale input fails; only the newest 64
  otherwise valid probes constrain the polygon. Retained inputs preserve provenance.

  An anchor supplies generation, sample_index, device_us, period_min_us,
  period_max_us and error_us. Its error covers acquisition/quantization in device
  units; its period interval must hold over the requested samples. Stream/epoch
  ownership and hardware evidence are caller contracts, never inferred here.
  """

  def fit([], _policy), do: {:unavailable, :no_probes}

  def fit(probes, policy) when is_list(probes) and is_map(policy) do
    with :ok <- check_policy(policy), :ok <- check_probes(probes, policy) do
      probes =
        probes
        |> Enum.reduce(:gb_sets.empty(), &retain_probe/2)
        |> :gb_sets.to_list()
        |> Enum.map(&elem(&1, 4))

      first = hd(probes)
      amin = q(policy.a_min)
      amax = q(policy.a_max)
      eps = q(policy.epsilon_us)
      lower = fn a -> sub(sub(q(first.h1), eps), mul(a, q(first.d2))) end
      upper = fn a -> sub(add(q(first.h4), eps), mul(a, q(first.d3))) end
      bmin = minq(lower.(amin), lower.(amax))
      bmax = maxq(upper.(amin), upper.(amax))

      rectangle =
        if le?(bmin, bmax),
          do: [{amin, bmin}, {amax, bmin}, {amax, bmax}, {amin, bmax}],
          else: []

      vertices =
        Enum.reduce(probes, rectangle, fn probe, polygon ->
          polygon
          |> clip({q(-probe.d2), q(-1), sub(eps, q(probe.h1))})
          |> clip({q(probe.d3), q(1), add(q(probe.h4), eps)})
        end)

      if vertices == [] do
        {:unavailable, :contradictory_probes}
      else
        {:ok,
         %{
           algorithm: "affine_polytope_v1",
           generation: policy.generation,
           valid_device_us: policy.valid_device_us,
           probe_span_us:
             {Enum.min(Enum.map(probes, & &1.d2)), Enum.max(Enum.map(probes, & &1.d3))},
           holdover_rate: q(policy.holdover_rate),
           vertices: vertices,
           probes: probes,
           policy: policy
         }}
      end
    end
  end

  def fit(_probes, _policy), do: {:unavailable, :invalid_input}

  def at_device_time(
        %{generation: generation} = estimate,
        %{generation: requested, device_us: time}
      ) do
    cond do
      requested != generation -> {:unavailable, :generation_mismatch}
      not rational?(time) -> {:unavailable, :invalid_device_time}
      true -> bounds(estimate, q(time), q(time))
    end
  end

  def at_device_time(_estimate, _query), do: {:unavailable, :invalid_query}

  def interval(%{generation: generation} = estimate, %{generation: requested} = anchor, index) do
    cond do
      requested != generation ->
        {:unavailable, :generation_mismatch}

      not valid_anchor?(anchor, index) ->
        {:unavailable, :invalid_anchor}

      true ->
        delta = q(index - anchor.sample_index)
        left = mul(delta, q(anchor.period_min_us))
        right = mul(delta, q(anchor.period_max_us))
        low = sub(add(q(anchor.device_us), minq(left, right)), q(anchor.error_us))
        high = add(add(q(anchor.device_us), maxq(left, right)), q(anchor.error_us))
        bounds(estimate, low, high)
    end
  end

  def interval(_estimate, _anchor, _index), do: {:unavailable, :invalid_anchor}

  defp bounds(estimate, low, high) do
    {valid_low, valid_high} = estimate.valid_device_us

    if le?(q(valid_low), low) and le?(high, q(valid_high)) do
      {observed_low, observed_high} = estimate.probe_span_us
      distance = maxq(q(0), maxq(sub(q(observed_low), low), sub(high, q(observed_high))))
      error = mul(distance, estimate.holdover_rate)
      earliest = estimate.vertices |> Enum.map(&value(&1, low)) |> Enum.reduce(&minq/2)
      latest = estimate.vertices |> Enum.map(&value(&1, high)) |> Enum.reduce(&maxq/2)
      {:ok, {floorq(sub(earliest, error)), ceilq(add(latest, error))}}
    else
      {:unavailable, :outside_validity}
    end
  end

  defp clip([], _plane), do: []

  defp clip([first | rest] = polygon, plane) do
    Enum.zip(polygon, rest ++ [first])
    |> Enum.flat_map(fn {p, next} ->
      fp = residual(p, plane)
      fnx = residual(next, plane)

      case {le?(fp, q(0)), le?(fnx, q(0))} do
        {true, true} -> [next]
        {true, false} -> [intersection(p, next, fp, fnx)]
        {false, true} -> [intersection(p, next, fp, fnx), next]
        {false, false} -> []
      end
    end)
    |> Enum.uniq()
  end

  defp residual({a, b}, {x, y, limit}), do: sub(add(mul(x, a), mul(y, b)), limit)

  defp intersection({a, b}, {c, d}, fp, fnx) do
    t = divide(fp, sub(fp, fnx))
    {add(a, mul(t, sub(c, a))), add(b, mul(t, sub(d, b)))}
  end

  defp retain_probe(probe, retained) do
    next = :gb_sets.add({probe.h4, probe.h1, probe.d2, probe.d3, probe}, retained)
    if :gb_sets.size(next) > 64, do: elem(:gb_sets.take_smallest(next), 1), else: next
  end

  defp check_policy(policy) do
    if valid_policy?(policy), do: :ok, else: {:unavailable, :invalid_policy}
  end

  defp valid_policy?(%{
         generation: generation,
         a_min: amin,
         a_max: amax,
         epsilon_us: eps,
         host_now_us: now,
         max_probe_age_us: age,
         valid_device_us: {low, high},
         holdover_rate: wander
       }) do
    not is_nil(generation) and is_integer(now) and is_integer(age) and age >= 0 and
      is_integer(low) and is_integer(high) and low <= high and
      Enum.all?([amin, amax, eps, wander], &rational?/1) and
      positive?(amin) and le?(q(amin), q(amax)) and nonnegative?(eps) and nonnegative?(wander)
  end

  defp valid_policy?(_policy), do: false

  defp check_probes(probes, policy) do
    {low, high} = policy.valid_device_us

    cond do
      not Enum.all?(probes, &valid_probe?/1) ->
        {:unavailable, :invalid_probe}

      Enum.any?(probes, &(&1.generation != policy.generation)) ->
        {:unavailable, :generation_mismatch}

      Enum.any?(probes, fn probe ->
        probe.h4 > policy.host_now_us or
            policy.host_now_us - probe.h4 > policy.max_probe_age_us
      end) ->
        {:unavailable, :stale_probe}

      Enum.any?(probes, &(&1.d2 < low or &1.d3 > high)) ->
        {:unavailable, :probe_outside_validity}

      true ->
        :ok
    end
  end

  defp valid_probe?(%{generation: _, h1: h1, d2: d2, d3: d3, h4: h4}) do
    Enum.all?([h1, d2, d3, h4], &is_integer/1) and h1 <= h4 and d2 <= d3
  end

  defp valid_probe?(_probe), do: false

  defp valid_anchor?(
         %{
           sample_index: origin,
           device_us: time,
           period_min_us: low,
           period_max_us: high,
           error_us: error
         },
         index
       ) do
    is_integer(origin) and origin >= 0 and is_integer(index) and index >= 0 and
      Enum.all?([time, low, high, error], &rational?/1) and
      positive?(low) and le?(q(low), q(high)) and nonnegative?(error)
  end

  defp valid_anchor?(_anchor, _index), do: false
  defp rational?(value) when is_integer(value), do: true
  defp rational?({n, d}) when is_integer(n) and is_integer(d) and d != 0, do: true
  defp rational?(_value), do: false
  defp positive?(value), do: not le?(q(value), q(0))
  defp nonnegative?(value), do: le?(q(0), q(value))
  defp q(n) when is_integer(n), do: {n, 1}
  defp q({n, d}) when d < 0, do: q({-n, -d})

  defp q({n, d}) do
    gcd = Integer.gcd(abs(n), d)
    {div(n, gcd), div(d, gcd)}
  end

  defp add({a, b}, {c, d}), do: q({a * d + c * b, b * d})
  defp sub({a, b}, {c, d}), do: q({a * d - c * b, b * d})
  defp mul({a, b}, {c, d}), do: q({a * c, b * d})
  defp divide({a, b}, {c, d}), do: q({a * d, b * c})
  defp le?({a, b}, {c, d}), do: a * d <= c * b
  defp minq(a, b), do: if(le?(a, b), do: a, else: b)
  defp maxq(a, b), do: if(le?(a, b), do: b, else: a)
  defp value({a, b}, device_time), do: add(mul(a, device_time), b)
  defp floorq({n, d}), do: Integer.floor_div(n, d)
  defp ceilq({n, d}), do: -Integer.floor_div(-n, d)
end
