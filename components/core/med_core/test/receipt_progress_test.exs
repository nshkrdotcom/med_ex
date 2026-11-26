defmodule MedEx.ReceiptProgressTest do
  use ExUnit.Case, async: true
  alias MedEx.Serialization

  @receipt %{
    stream_id: "ecg",
    source_epoch: 0,
    descriptor_ref: String.duplicate("a", 64),
    fence: "one",
    journal_id: "journal",
    journal_generation: 2,
    journal_digest: String.duplicate("b", 64),
    accepted_sequence: 4,
    durable_sequence: 4,
    accepted_sample: 100,
    durable_sample: 100
  }

  test "receipt progression keeps journal continuity separate from verified handoff" do
    r = @receipt
    assert :ok = Serialization.receipt_progress(r, r)

    assert {:error, :not_durable_receipt} =
             Serialization.receipt_progress(r, %{r | accepted_sample: 101})

    assert {:error, :receipt_rollback} =
             Serialization.receipt_progress(r, %{r | accepted_sample: 99, durable_sample: 99})

    assert {:error, :receipt_identity} = Serialization.receipt_progress(r, %{r | source_epoch: 1})

    assert {:error, :receipt_conflict} =
             Serialization.receipt_progress(r, %{r | journal_digest: String.duplicate("c", 64)})

    newer = %{r | journal_generation: 3, journal_digest: String.duplicate("e", 64)}

    assert :ok =
             Serialization.receipt_progress(r, %{
               newer
               | durable_sample: 101,
                 accepted_sample: 101
             })

    assert_raise FunctionClauseError, fn ->
      Serialization.receipt_progress(r, r, String.to_atom("typo"))
    end

    for context <- [:same_attempt, :verified_handoff],
        {changes, error} <- [
          {%{accepted_sequence: 5}, :not_durable_receipt},
          {%{durable_sequence: 3, accepted_sequence: 3}, :receipt_rollback},
          {%{stream_id: "audio", durable_sample: 1, accepted_sample: 1}, :receipt_identity},
          {%{descriptor_ref: String.duplicate("f", 64)}, :receipt_identity},
          {%{journal_id: "other"}, :receipt_rollback},
          {%{journal_generation: 1}, :receipt_rollback},
          {%{journal_generation: 3}, :receipt_conflict},
          {%{accepted_sequence: 5, durable_sequence: 5}, :receipt_conflict}
        ] do
      assert {:error, ^error} = Serialization.receipt_progress(r, Map.merge(r, changes), context)
    end

    next = %{r | fence: "two", journal_id: "successor", journal_generation: 1}
    assert {:error, :receipt_identity} = Serialization.receipt_progress(r, next)
    assert :ok = Serialization.receipt_progress(r, next, :verified_handoff)
    assert ^r = Serialization.durable_prefix(%{r | accepted_sequence: 5, accepted_sample: 120})
  end
end
