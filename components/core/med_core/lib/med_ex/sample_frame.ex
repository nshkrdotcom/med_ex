defmodule MedEx.SampleFrame do
  @moduledoc "Host-bound waveform value; wire framing alone does not produce an admitted frame."
  alias MedEx.{ContractRules, StreamSpec}

  @enforce_keys [
    :stream_id,
    :source_epoch,
    :descriptor_ref,
    :sequence,
    :first_sample,
    :sample_count,
    :config_epoch,
    :payload
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stream_id: String.t(),
          source_epoch: non_neg_integer(),
          descriptor_ref: String.t(),
          sequence: non_neg_integer(),
          first_sample: non_neg_integer(),
          sample_count: pos_integer(),
          config_epoch: :unknown | non_neg_integer(),
          payload: binary()
        }
  @u64 0xFFFFFFFFFFFFFFFF
  @spec validate(term(), StreamSpec.t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = f, %StreamSpec{} = s) do
    with :ok <- StreamSpec.validate(s) do
      cond do
        {f.stream_id, f.source_epoch, f.descriptor_ref} !=
            {s.stream_id, s.source_epoch, s.descriptor_ref} ->
          {:error, :descriptor_mismatch}

        not ContractRules.uint?(f.sequence, @u64) or not ContractRules.uint?(f.first_sample, @u64) ->
          {:error, :invalid_counter}

        not ContractRules.uint?(f.sample_count, s.capabilities.max_frame_samples) or
            f.sample_count == 0 ->
          {:error, :invalid_sample_count}

        f.first_sample + f.sample_count > @u64 ->
          {:error, :sample_overflow}

        not ContractRules.config?(f.config_epoch) ->
          {:error, :invalid_config_epoch}

        not is_binary(f.payload) ->
          {:error, :invalid_payload}

        byte_size(f.payload) > s.capabilities.max_payload_bytes ->
          {:error, :payload_limit}

        byte_size(f.payload) !=
            f.sample_count * length(s.channels) * StreamSpec.bytes_per_value(s.encoding) ->
          {:error, :stride_mismatch}

        true ->
          :ok
      end
    end
  end

  def validate(_, _), do: {:error, :invalid_frame}
end
