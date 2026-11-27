defmodule MedEx.ReceiptProgressTest do
  use ExUnit.Case, async: true
  alias MedEx.{Receipt, Serialization}
  @fixture Path.join(__DIR__, "fixtures/receipt_vectors_v2.json")

  test "one hashed corpus proves canonical shape, identity, commit/observe and handoff" do
    bytes = File.read!(@fixture)

    [expected_hash, _] =
      File.read!(@fixture |> String.replace(".json", ".sha256")) |> String.split()

    assert Serialization.sha256(bytes) == expected_hash
    corpus = JSON.decode!(bytes)
    assert corpus["api_revision"] == 2
    assert length(corpus["cases"]) >= 50

    for vector <- corpus["cases"] do
      assert outcome(vector) == vector["expected"], vector["id"]
    end
  end

  defp outcome(%{"operation" => "parse", "proposed" => proposed}),
    do: result(Receipt.parse(proposed))

  defp outcome(vector) do
    {:ok, previous} = Receipt.parse(vector["previous"])
    {:ok, proposed} = Receipt.parse(vector["proposed"])

    case vector["operation"] do
      "observe" ->
        result(Receipt.observe(previous, proposed))

      "commit" ->
        cursor = vector["planned_cursor"]

        result(
          Receipt.committed_successor(previous, proposed, %{
            next_sequence: String.to_integer(cursor["next_sequence"]),
            next_sample: String.to_integer(cursor["next_sample"])
          })
        )

      "exact" ->
        to_string(Receipt.exact_prefix?(previous, proposed))

      "handoff" ->
        result(Receipt.handoff(previous, proposed, vector_binding(vector["binding"])))
    end
  end

  defp vector_binding(value) when is_map(value),
    do: %{
      authority: :authenticated_host,
      authenticated: value["authenticated"],
      quiescent: value["quiescent"],
      previous: value["previous"],
      successor: value["successor"],
      imported: value["imported"]
    }

  defp vector_binding(value), do: value
  defp result(:ok), do: "ok"
  defp result({:ok, _}), do: "ok"
  defp result({:error, reason}), do: Atom.to_string(reason)

  test "normalization is not a durable assertion and counters above JS precision remain exact" do
    vector = JSON.decode!(File.read!(@fixture))["cases"] |> hd()
    {:ok, r} = Receipt.parse(vector["proposed"])
    volatile = %{r | accepted_sample: r.durable_sample + 1}
    refute Receipt.durable?(volatile)
    assert Receipt.durable_prefix(volatile) == r
    refute Receipt.exact_prefix?(volatile, r)
    huge = %{r | durable_sample: 9_007_199_254_740_993, accepted_sample: 9_007_199_254_740_993}
    assert {:ok, ^huge} = Receipt.parse(Receipt.to_map(huge))
  end

  test "unchecked or malformed recovered identity cannot become handoff evidence" do
    vector =
      JSON.decode!(File.read!(@fixture))["cases"]
      |> Enum.find(&(&1["operation"] == "handoff" and &1["expected"] == "ok"))

    {:ok, previous} = Receipt.parse(vector["previous"])
    {:ok, successor} = Receipt.parse(vector["proposed"])

    for stream <- [nil, 1, [], %{}, %{stream_id: previous.stream_id}] do
      imported = %{
        receipt: previous,
        provenance: %{scope: :full_journal, receipt: previous},
        stream: stream,
        fence: previous.fence
      }

      assert {:error, :unverified_handoff} =
               Receipt.handoff(previous, successor, %{
                 authority: :verified_storage,
                 authenticated: true,
                 quiescent: true,
                 previous: previous,
                 successor: successor,
                 imported: imported
               })
    end
  end

  test "seed 20261126 generated observer and single-commit boundaries agree" do
    :rand.seed(:exsss, {2026, 11, 26})
    first = JSON.decode!(File.read!(@fixture))["cases"] |> hd()
    {:ok, base} = Receipt.parse(first["proposed"])

    for generation <- 1..50 do
      sequence = :rand.uniform(100_000)
      sample = sequence * 960

      old = %{
        base
        | journal_generation: generation,
          journal_digest: Serialization.sha256("old-#{generation}"),
          accepted_sequence: sequence,
          durable_sequence: sequence,
          accepted_sample: sample,
          durable_sample: sample
      }

      jump = :rand.uniform(5)

      next = %{
        old
        | journal_generation: generation + jump,
          journal_digest: Serialization.sha256("new-#{generation}"),
          accepted_sequence: sequence + 1,
          durable_sequence: sequence + 1,
          accepted_sample: sample + 960,
          durable_sample: sample + 960
      }

      assert :ok = Receipt.observe(old, next)
      planned = %{next_sequence: sequence + 1, next_sample: sample + 960}

      if jump == 1,
        do: assert(:ok = Receipt.committed_successor(old, next, planned)),
        else:
          assert({:error, :unexpected_commit} = Receipt.committed_successor(old, next, planned))

      assert {:error, :receipt_conflict} =
               Receipt.observe(old, %{next | journal_digest: old.journal_digest})

      assert {:error, :receipt_identity} = Receipt.observe(old, %{next | fence: "different"})
      assert {:ok, ^next} = Receipt.parse(Receipt.to_map(next))
    end
  end
end
