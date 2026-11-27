defmodule MedEx.Wire.Credit do
  @moduledoc """
  Bounded source-record credit for one authenticated connection and stream.

  Both a frame (including its 48-byte header) and a canonical gap message cost
  one slot and their full encoded bytes. Callers validate receipt identity,
  progression and local coverage through `MedEx.Receipt` before acknowledging.
  This ledger accounts for outstanding operations; it grants no authority and
  never permits deletion of source records. A known refusal releases only credit.
  Connection replacement invalidates the ledger, leaving source retention to
  its owner. No sequence-delta inference or volatile acceptance releases credit.
  """
  alias MedEx.Receipt
  @enforce_keys [:binding, :frame_limit, :byte_limit]
  defstruct @enforce_keys ++ [operations: %{}, bytes: 0]
  @type t :: %__MODULE__{}
  @max_counter 0xFFFFFFFFFFFFFFFF

  @spec new(map(), pos_integer(), pos_integer()) :: {:ok, t()} | {:error, atom()}
  def new(binding, frame_limit \\ 15, byte_limit \\ 262_144)

  def new(binding, frames, bytes)
      when is_map(binding) and map_size(binding) > 0 and is_integer(frames) and
             frames in 1..15 and is_integer(bytes) and bytes in 1..262_144,
      do: {:ok, %__MODULE__{binding: binding, frame_limit: frames, byte_limit: bytes}}

  def new(_, _, _), do: {:error, :invalid_credit}

  @spec reserve(t(), map(), map()) :: {:ok, t(), :new | :duplicate} | {:error, atom()}
  def reserve(%__MODULE__{binding: expected} = ledger, binding, operation)
      when is_map(expected) and binding == expected do
    with :ok <- valid_operation(operation) do
      case Map.fetch(ledger.operations, operation.id) do
        {:ok, ^operation} ->
          {:ok, ledger, :duplicate}

        {:ok, _} ->
          {:error, :conflicting_operation}

        :error ->
          reserve_new(ledger, operation)
      end
    end
  end

  def reserve(%__MODULE__{}, _, _), do: {:error, :stale_binding}
  def reserve(_, _, _), do: {:error, :invalid_credit}

  defp reserve_new(ledger, operation) do
    if map_size(ledger.operations) < ledger.frame_limit and
         ledger.bytes + operation.bytes <= ledger.byte_limit do
      {:ok,
       %{
         ledger
         | operations: Map.put(ledger.operations, operation.id, operation),
           bytes: ledger.bytes + operation.bytes
       }, :new}
    else
      {:error, :credit_exhausted}
    end
  end

  @doc "Return one exact outstanding operation only for its current connection binding."
  @spec lookup(t(), map(), binary()) :: {:ok, map()} | {:error, atom()}
  def lookup(%__MODULE__{binding: expected} = ledger, binding, id)
      when is_map(expected) and binding == expected and is_binary(id) do
    case Map.fetch(ledger.operations, id) do
      {:ok, operation} -> {:ok, operation}
      :error -> {:error, :unknown_operation}
    end
  end

  def lookup(%__MODULE__{binding: expected}, binding, _)
      when is_map(expected) and binding == expected,
      do: {:error, :unknown_operation}

  def lookup(%__MODULE__{}, _, _), do: {:error, :stale_binding}
  def lookup(_, _, _), do: {:error, :invalid_credit}

  @spec acknowledge(t(), map(), Receipt.t()) :: {:ok, t(), [binary()]} | {:error, atom()}
  def acknowledge(%__MODULE__{binding: expected} = ledger, binding, %Receipt{} = receipt)
      when is_map(expected) and binding == expected do
    if Receipt.durable?(receipt) do
      {released, retained} =
        Enum.split_with(ledger.operations, fn {_id, operation} ->
          operation.sequence <= receipt.durable_sequence and
            operation.sample <= receipt.durable_sample
        end)

      bytes = Enum.reduce(released, 0, fn {_id, operation}, total -> total + operation.bytes end)

      {:ok, %{ledger | operations: Map.new(retained), bytes: ledger.bytes - bytes},
       released |> Enum.map(&elem(&1, 0)) |> Enum.sort()}
    else
      {:error, :volatile_receipt}
    end
  end

  def acknowledge(%__MODULE__{binding: expected}, binding, _)
      when is_map(expected) and binding == expected, do: {:error, :invalid_receipt}

  def acknowledge(%__MODULE__{}, _, _), do: {:error, :stale_binding}
  def acknowledge(_, _, _), do: {:error, :invalid_credit}

  @spec refuse(t(), map(), binary(), binary()) :: {:ok, t()} | {:error, atom()}
  def refuse(%__MODULE__{binding: expected} = ledger, binding, id, fingerprint)
      when is_map(expected) and binding == expected and is_binary(id) and is_binary(fingerprint) do
    case Map.fetch(ledger.operations, id) do
      {:ok, %{fingerprint: ^fingerprint, bytes: bytes}} ->
        {:ok,
         %{ledger | operations: Map.delete(ledger.operations, id), bytes: ledger.bytes - bytes}}

      {:ok, _} ->
        {:error, :conflicting_operation}

      :error ->
        {:ok, ledger}
    end
  end

  def refuse(%__MODULE__{}, _, _, _), do: {:error, :stale_binding}
  def refuse(_, _, _, _), do: {:error, :invalid_credit}

  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{} = ledger), do: %{ledger | binding: nil, operations: %{}, bytes: 0}

  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = ledger),
    do: %{
      outstanding_frames: map_size(ledger.operations),
      outstanding_bytes: ledger.bytes,
      available_frames: ledger.frame_limit - map_size(ledger.operations),
      available_bytes: ledger.byte_limit - ledger.bytes
    }

  defp valid_operation(
         %{id: id, fingerprint: hash, bytes: bytes, sequence: sequence, sample: sample} = op
       )
       when map_size(op) == 5 and is_binary(id) and byte_size(id) in 1..96 and
              is_binary(hash) and byte_size(hash) == 64 and is_integer(bytes) and bytes > 0 do
    if operation_values?(id, hash, sequence, sample),
      do: :ok,
      else: {:error, :invalid_operation}
  end

  defp valid_operation(_), do: {:error, :invalid_operation}

  defp operation_values?(id, hash, sequence, sample) do
    counter?(sequence) and counter?(sample) and valid_identity?(id, hash)
  end

  defp counter?(value), do: is_integer(value) and value >= 0 and value <= @max_counter

  defp valid_identity?(id, hash) do
    Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)
  end
end
