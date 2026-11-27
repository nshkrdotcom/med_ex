defmodule MedEx.Receipt do
  @moduledoc """
  Canonical technical journal receipt. Parsing establishes shape, not actor
  authority. Hosts bind receipts to authenticated attempts and verified storage;
  source clients additionally prove retained local coverage before reclamation.
  All counters on the wire are canonical decimal strings.
  """
  alias MedEx.{ContractRules, RecordingLimits, Serialization, StreamIndex}
  @ids ~w(stream_id source_epoch descriptor_ref fence journal_id)a
  @counts ~w(source_epoch journal_generation accepted_sequence accepted_sample durable_sequence durable_sample)a
  @fields ~w(stream_id source_epoch descriptor_ref fence journal_id journal_generation journal_digest accepted_sequence accepted_sample durable_sequence durable_sample)a
  @enforce_keys @fields
  defstruct @fields
  @type t :: %__MODULE__{}
  @max 0xFFFFFFFFFFFFFFFF

  @spec parse(term()) :: {:ok, t()} | {:error, atom()}
  def parse(%__MODULE__{} = receipt) do
    if valid?(receipt), do: {:ok, receipt}, else: {:error, :invalid_receipt}
  end

  def parse(wire) when is_map(wire) and map_size(wire) == 11 do
    values =
      Map.new(@fields, fn key ->
        value = Map.fetch!(wire, Atom.to_string(key))
        {key, if(key in @counts, do: Serialization.integer!(value), else: value)}
      end)

    receipt = struct!(__MODULE__, values)

    if valid?(receipt) and to_map(receipt) == wire,
      do: {:ok, receipt},
      else: {:error, :invalid_receipt}
  rescue
    _ in [ArgumentError, FunctionClauseError, BadMapError, KeyError] -> {:error, :invalid_receipt}
  end

  def parse(_), do: {:error, :invalid_receipt}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = receipt) do
    Map.new(@fields, fn key ->
      value = Map.fetch!(receipt, key)
      {Atom.to_string(key), if(key in @counts, do: Integer.to_string(value), else: value)}
    end)
  end

  defp valid?(r) do
    Enum.all?([r.stream_id, r.fence, r.journal_id], &ContractRules.id?/1) and
      ContractRules.digest?(r.descriptor_ref) and ContractRules.digest?(r.journal_digest) and
      Enum.all?(@counts, &ContractRules.uint?(Map.fetch!(r, &1), @max)) and
      r.source_epoch <= 0xFFFFFFFF and r.journal_generation >= 1 and
      r.journal_generation <= RecordingLimits.maximum().generations and
      r.accepted_sequence >= r.durable_sequence and r.accepted_sample >= r.durable_sample
  end

  @spec validate_identity(t(), map()) :: :ok | {:error, atom()}
  def validate_identity(receipt, expected) when is_map(expected) do
    with {:ok, r} <- parse(receipt),
         true <-
           Enum.all?(
             [:stream_id, :source_epoch, :descriptor_ref, :fence],
             &Map.has_key?(expected, &1)
           ),
         true <-
           Enum.all?(@ids, fn key ->
             not Map.has_key?(expected, key) or Map.fetch!(r, key) == Map.fetch!(expected, key)
           end) do
      :ok
    else
      _ -> {:error, :receipt_identity}
    end
  end

  def validate_identity(_, _), do: {:error, :receipt_identity}

  @spec durable?(term()) :: boolean()
  def durable?(receipt) do
    case parse(receipt) do
      {:ok, r} ->
        r.accepted_sequence == r.durable_sequence and r.accepted_sample == r.durable_sample

      _ ->
        false
    end
  end

  @doc "Discard speculative accepted progress; this does not prove durability."
  @spec durable_prefix(t()) :: t()
  def durable_prefix(%__MODULE__{} = r),
    do: %{r | accepted_sequence: r.durable_sequence, accepted_sample: r.durable_sample}

  @spec observe(t(), t()) :: :ok | {:error, atom()}
  def observe(previous, proposed) do
    with {:ok, last} <- parse(previous),
         {:ok, next} <- parse(proposed),
         :ok <- validate_identity(next, last),
         true <- durable?(next) do
      cond do
        next.durable_sequence < last.durable_sequence or next.durable_sample < last.durable_sample or
            next.journal_generation < last.journal_generation ->
          {:error, :receipt_rollback}

        next.journal_generation == last.journal_generation and durable_prefix(last) != next ->
          {:error, :receipt_conflict}

        next.journal_generation > last.journal_generation and
            next.journal_digest == last.journal_digest ->
          {:error, :receipt_conflict}

        true ->
          :ok
      end
    else
      false -> {:error, :not_durable_receipt}
      error -> error
    end
  end

  @spec committed_successor(t(), t(), map()) :: :ok | {:error, atom()}
  def committed_successor(previous, proposed, %{next_sequence: sequence, next_sample: sample}) do
    with {:ok, last} <- parse(previous),
         {:ok, next} <- parse(proposed),
         :ok <- observe(last, next),
         true <- next.journal_generation == last.journal_generation + 1,
         true <- {next.durable_sequence, next.durable_sample} == {sequence, sample} do
      :ok
    else
      false -> {:error, :unexpected_commit}
      error -> error
    end
  end

  def committed_successor(_, _, _), do: {:error, :invalid_planned_cursor}

  @spec exact_prefix?(term(), term()) :: boolean()
  def exact_prefix?(expected, %{receipt: recovered}), do: exact_prefix?(expected, recovered)

  def exact_prefix?(expected, recovered) do
    with {:ok, a} <- parse(expected), {:ok, b} <- parse(recovered) do
      durable?(a) and durable?(b) and a == b
    else
      _ -> false
    end
  end

  @doc """
  Validate a successor against the exact imported predecessor. A host supplies
  its verified recovery and quiescence facts. A source supplies a host assertion
  only after authenticating the current transport binding. Neither form grants
  authority by itself, and neither replaces local retained-record coverage.
  """
  def handoff(previous, successor, binding) when is_map(binding) do
    with {:ok, old} <- parse(previous),
         {:ok, new} <- parse(successor),
         true <- durable?(old) and durable?(new),
         true <-
           Enum.all?(
             [:stream_id, :source_epoch, :descriptor_ref],
             &(Map.fetch!(old, &1) == Map.fetch!(new, &1))
           ),
         true <- old.fence != new.fence and old.journal_id != new.journal_id,
         true <-
           new.durable_sequence == old.durable_sequence and
             new.durable_sample == old.durable_sample,
         true <- new.journal_generation == 1,
         true <-
           exact_prefix?(old, binding[:previous]) and exact_prefix?(new, binding[:successor]),
         :ok <- imported_prefix(old, binding) do
      :ok
    else
      false -> {:error, :unverified_handoff}
      {:error, _} = error -> error
    end
  end

  def handoff(_, _, _), do: {:error, :unverified_handoff}

  defp imported_prefix(old, %{
         authority: :authenticated_host,
         imported: imported,
         authenticated: true,
         quiescent: true
       }) do
    if exact_prefix?(old, imported), do: :ok, else: {:error, :unverified_handoff}
  end

  defp imported_prefix(old, %{
         authority: :verified_storage,
         authenticated: true,
         quiescent: true,
         imported: %{
           receipt: imported,
           provenance: provenance,
           stream: %{
             stream_id: stream_id,
             source_epoch: source_epoch,
             descriptor_ref: descriptor_ref
           },
           fence: fence
         }
       })
       when is_map(provenance) do
    if exact_prefix?(old, imported) and
         {stream_id, source_epoch, descriptor_ref, fence} ==
           {old.stream_id, old.source_epoch, old.descriptor_ref, old.fence} and
         provenance[:scope] == :full_journal and provenance[:receipt] == old,
       do: :ok,
       else: {:error, :unverified_handoff}
  end

  defp imported_prefix(_, _), do: {:error, :unverified_handoff}

  @doc "Derive terminal truth from the exact installed index and verified journal."
  def terminal_receipt(%StreamIndex{} = index, recovered, previous) when is_map(recovered) do
    with :ok <- StreamIndex.validate(index),
         {:ok, receipt} <- parse(Map.get(recovered, :receipt)),
         true <-
           durable?(receipt) and Map.get(recovered, :index) == index and
             Map.get(recovered, :terminal_recorded) == true,
         true <-
           Map.get(recovered, :index_status) == :installed and Map.get(recovered, :sealed) == true,
         true <- Map.get(recovered, :index_digest) == Serialization.digest(index),
         %{scope: :full_journal, receipt: ^receipt} <- Map.get(recovered, :provenance),
         :ok <-
           validate_identity(receipt, %{
             stream_id: index.stream.stream_id,
             source_epoch: index.stream.source_epoch,
             descriptor_ref: index.stream.descriptor_ref,
             fence: index.fence,
             journal_id: index.journal_id
           }),
         true <-
           {receipt.journal_generation, receipt.journal_digest, receipt.durable_sequence,
            receipt.durable_sample} ==
             {index.journal_generation, index.journal_digest, index.next_sequence,
              index.next_sample},
         :ok <- terminal_progress(previous, receipt, index) do
      {:ok, receipt}
    else
      _ -> {:error, :unverified_terminal}
    end
  end

  def terminal_receipt(_, _, _), do: {:error, :unverified_terminal}

  defp terminal_progress(previous, next, index) do
    if exact_prefix?(previous, next),
      do: :ok,
      else:
        committed_successor(previous, next, %{
          next_sequence: index.next_sequence,
          next_sample: index.next_sample
        })
  end
end
