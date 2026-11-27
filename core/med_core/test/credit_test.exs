defmodule MedEx.Wire.CreditTest do
  use ExUnit.Case, async: true
  alias MedEx.Wire.Credit

  @binding %{"acquisition" => "a", "generation" => "1", "connection" => "c"}
  @fingerprint String.duplicate("a", 64)

  defp operation(id, sequence, sample, bytes \\ 100),
    do: %{id: id, fingerprint: @fingerprint, sequence: sequence, sample: sample, bytes: bytes}

  test "slot and encoded byte bounds are independent and duplicate is not charged twice" do
    assert {:ok, ledger} = Credit.new(@binding, 2, 150)
    assert {:ok, one, :new} = Credit.reserve(ledger, @binding, operation("frame-1", 1, 960))
    assert {:ok, ^one, :duplicate} = Credit.reserve(one, @binding, operation("frame-1", 1, 960))

    assert {:error, :credit_exhausted} =
             Credit.reserve(one, @binding, operation("frame-2", 2, 1920))

    assert {:error, :conflicting_operation} =
             Credit.reserve(one, @binding, %{operation("frame-1", 1, 960) | bytes: 101})

    assert %{outstanding_frames: 1, outstanding_bytes: 100} = Credit.stats(one)
  end

  test "sample-only gap consumes a slot and is released only with both coordinates covered" do
    {:ok, ledger} = Credit.new(@binding)
    {:ok, ledger, :new} = Credit.reserve(ledger, @binding, operation("gap-1", 0, 100))

    receipt = %MedEx.Receipt{
      stream_id: "audio",
      source_epoch: 1,
      descriptor_ref: @fingerprint,
      fence: "f",
      journal_id: "j",
      journal_generation: 1,
      journal_digest: @fingerprint,
      accepted_sequence: 0,
      accepted_sample: 50,
      durable_sequence: 0,
      durable_sample: 50
    }

    assert {:ok, ^ledger, []} = Credit.acknowledge(ledger, @binding, receipt)
    receipt = %{receipt | accepted_sample: 100, durable_sample: 100}
    assert {:ok, empty, ["gap-1"]} = Credit.acknowledge(ledger, @binding, receipt)
    assert {:ok, ^empty, []} = Credit.acknowledge(empty, @binding, receipt)
    assert %{outstanding_frames: 0, outstanding_bytes: 0} = Credit.stats(empty)

    assert {:error, :volatile_receipt} =
             Credit.acknowledge(ledger, @binding, %{receipt | accepted_sample: 101})
  end

  test "known refusal returns credit once without claiming durability" do
    {:ok, ledger} = Credit.new(@binding)
    {:ok, ledger, :new} = Credit.reserve(ledger, @binding, operation("frame-1", 1, 960))

    assert {:error, :conflicting_operation} =
             Credit.refuse(ledger, @binding, "frame-1", String.duplicate("b", 64))

    assert {:ok, empty} = Credit.refuse(ledger, @binding, "frame-1", @fingerprint)
    assert {:ok, ^empty} = Credit.refuse(empty, @binding, "frame-1", @fingerprint)
    assert %{available_frames: 15, available_bytes: 262_144} = Credit.stats(empty)
  end

  test "operation context lookup is exact, bounded and invalidated with its binding" do
    {:ok, ledger} = Credit.new(@binding)
    op = operation("frame-1", 1, 960)
    {:ok, ledger, :new} = Credit.reserve(ledger, @binding, op)
    assert {:ok, ^op} = Credit.lookup(ledger, @binding, "frame-1")
    assert {:error, :unknown_operation} = Credit.lookup(ledger, @binding, "absent")
    assert {:error, :unknown_operation} = Credit.lookup(ledger, @binding, nil)

    assert {:error, :stale_binding} =
             Credit.lookup(ledger, Map.put(@binding, "connection", "old"), "frame-1")

    assert {:error, :stale_binding} =
             Credit.lookup(Credit.invalidate(ledger), @binding, "frame-1")

    assert {:error, :invalid_credit} = Credit.lookup(nil, @binding, "frame-1")
  end

  test "connection replacement and local invalidation reject authentic old replies" do
    {:ok, ledger} = Credit.new(@binding)
    stale = Map.put(@binding, "connection", "old")
    assert {:error, :stale_binding} = Credit.reserve(ledger, stale, operation("frame-1", 1, 960))
    retired = Credit.invalidate(ledger)

    assert {:error, :stale_binding} =
             Credit.reserve(retired, @binding, operation("frame-1", 1, 960))

    assert {:error, :stale_binding} = Credit.refuse(retired, @binding, "frame-1", @fingerprint)
  end

  test "all boundary shapes are total and fifteen maximum-size requests cannot exceed byte budget" do
    for slots <- [0, 16, nil, "15"],
        do: assert({:error, :invalid_credit} = Credit.new(@binding, slots, 100))

    for bytes <- [0, 262_145, nil, "100"],
        do: assert({:error, :invalid_credit} = Credit.new(@binding, 1, bytes))

    {:ok, ledger} = Credit.new(@binding)
    assert {:error, :invalid_operation} = Credit.reserve(ledger, @binding, nil)

    assert {:error, :invalid_operation} =
             Credit.reserve(ledger, @binding, %{operation("x", 1, 1) | bytes: -1})

    ledger =
      Enum.reduce(1..3, ledger, fn n, state ->
        {:ok, next, :new} =
          Credit.reserve(state, @binding, operation("f#{n}", n, n * 32_768, 65_584))

        next
      end)

    assert {:error, :credit_exhausted} =
             Credit.reserve(ledger, @binding, operation("f4", 4, 131_072, 65_584))
  end
end
