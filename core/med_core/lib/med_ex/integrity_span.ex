defmodule MedEx.IntegritySpan do
  @moduledoc "A source fact over a half-open sample range OR a nonempty set of event IDs."
  alias MedEx.ContractRules, as: R
  @enforce_keys [:stream_id, :source_epoch, :code, :source]
  defstruct @enforce_keys ++
              [first_sample: nil, end_sample: nil, event_ids: [], record_refs: [], context: %{}]

  @type t :: %__MODULE__{
          stream_id: String.t(),
          source_epoch: non_neg_integer(),
          code: atom(),
          source: String.t(),
          first_sample: non_neg_integer() | nil,
          end_sample: non_neg_integer() | nil,
          event_ids: [String.t()],
          record_refs: [String.t()],
          context: map()
        }
  def validate(%__MODULE__{} = s) do
    valid =
      R.id?(s.stream_id) and R.uint?(s.source_epoch, 0xFFFFFFFF) and R.id?(s.source) and
        s.code in [
          :source_gap,
          :clock_unavailable,
          :configuration_unknown,
          :device_status_invalid,
          :source_processing_unverified,
          :duplicate_conflict
        ] and range?(s) and
        R.list?(s.record_refs, 64, &R.id?/1) and is_map(s.context) and map_size(s.context) <= 32 and
        Enum.all?(s.context, fn {k, v} -> R.key?(k) and R.scalar?(v) end)

    if valid, do: :ok, else: {:error, :invalid_integrity_span}
  end

  def validate(_), do: {:error, :invalid_integrity_span}

  defp range?(%{first_sample: nil, end_sample: nil, event_ids: ids}),
    do: ids != [] and R.list?(ids, 256, &R.id?/1)

  defp range?(%{first_sample: first, end_sample: last, event_ids: []}) do
    R.uint?(first, 0xFFFFFFFFFFFFFFFF) and R.uint?(last, 0xFFFFFFFFFFFFFFFF) and first < last
  end

  defp range?(_), do: false
end
