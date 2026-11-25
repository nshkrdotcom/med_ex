defmodule MedEx.SegmentRef do
  @moduledoc "Immutable native-byte chunk reference. A chunk boundary does not imply a gap."
  alias MedEx.ContractRules, as: R

  @enforce_keys [
    :key,
    :sha256,
    :byte_size,
    :first_sample,
    :end_sample,
    :first_sequence,
    :next_sequence,
    :descriptor_ref,
    :config_epoch
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          key: String.t(),
          sha256: String.t(),
          byte_size: pos_integer(),
          first_sample: non_neg_integer(),
          end_sample: pos_integer(),
          first_sequence: non_neg_integer(),
          next_sequence: pos_integer(),
          descriptor_ref: String.t(),
          config_epoch: :unknown | non_neg_integer()
        }
  def validate(%__MODULE__{} = s) do
    valid =
      R.id?(s.key) and R.digest?(s.sha256) and R.digest?(s.descriptor_ref) and
        R.uint?(s.byte_size, 262_144) and s.byte_size > 0 and R.config?(s.config_epoch) and
        Enum.all?(
          [s.first_sample, s.end_sample, s.first_sequence, s.next_sequence],
          &R.uint?(&1, 0xFFFFFFFFFFFFFFFF)
        ) and
        s.first_sample < s.end_sample and s.first_sequence < s.next_sequence and
        s.next_sequence - s.first_sequence <= s.end_sample - s.first_sample

    if valid, do: :ok, else: {:error, :invalid_segment}
  end

  def validate(_), do: {:error, :invalid_segment}
end
