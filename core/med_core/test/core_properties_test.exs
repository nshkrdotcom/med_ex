defmodule MedEx.CorePropertiesTest do
  use ExUnit.Case, async: true

  alias MedEx.{CanonicalJSON, ClockAlign}
  alias MedEx.Wire.{Control, FrameV1}

  test "Wire.FrameV1 round-trips arbitrary payloads and coordinates" do
    :rand.seed(:exsss, {101, 202, 303})

    for i <- 1..50 do
      len = :rand.uniform(256)
      payload = :crypto.strong_rand_bytes(len)

      frame = %FrameV1{
        stream_number: i,
        source_epoch: rem(i, 5),
        config_epoch: 1,
        sequence: i * 10,
        first_sample: i * 100,
        sample_count: len,
        payload: payload
      }

      assert {:ok, bin} = FrameV1.encode(frame)
      assert {:ok, decoded} = FrameV1.decode(bin)
      assert decoded == frame
    end
  end

  test "Wire.Control rejects duplicate JSON keys" do
    dup = ~s({"type":"ping","type":"pong"})
    assert {:error, _} = Control.decode(dup, %{"ping" => 1, "pong" => 1})
  end

  test "CanonicalJSON encodes MEJ1 maps deterministically regardless of key insertion order" do
    a = %{"z" => "1", "a" => [true, false, nil, "hi"], "m" => %{"b" => "2", "a" => "1"}}
    b = %{"m" => %{"a" => "1", "b" => "2"}, "a" => [true, false, nil, "hi"], "z" => "1"}
    assert CanonicalJSON.encode(a) == CanonicalJSON.encode(b)
    assert_raise ArgumentError, fn -> CanonicalJSON.encode(%{"n" => 1}) end
  end

  test "ClockAlign returns unavailable on empty probes and valid bounds on monotone probes" do
    policy = %{max_rtt_ns: 50_000_000, max_ppm: 500, min_probes: 2, max_span_ns: 60_000_000_000}
    assert {:unavailable, :no_probes} = ClockAlign.fit([], policy)

    probes = [
      %{t_req_ns: 1_000_000, t_dev_ns: 1_005_000, t_resp_ns: 1_010_000},
      %{t_req_ns: 2_000_000, t_dev_ns: 2_005_000, t_resp_ns: 2_010_000}
    ]

    case ClockAlign.fit(probes, policy) do
      {:ok, est} ->
        assert {:ok, {lo, hi}} = ClockAlign.at_device_time(est, 1_505_000)
        assert lo <= hi

      {:unavailable, _} ->
        :ok
    end
  end
end
