defmodule MedEx.Wire.FrameV1 do
  @moduledoc "MEX1 framing only. Authenticate the numeric handle and validate against its descriptor separately."
  alias MedEx.ContractRules, as: R

  @enforce_keys [
    :stream_number,
    :source_epoch,
    :config_epoch,
    :sequence,
    :first_sample,
    :sample_count,
    :payload
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stream_number: non_neg_integer(),
          source_epoch: non_neg_integer(),
          config_epoch: :unknown | non_neg_integer(),
          sequence: non_neg_integer(),
          first_sample: non_neg_integer(),
          sample_count: pos_integer(),
          payload: binary()
        }
  @u64 0xFFFFFFFFFFFFFFFF
  @unknown 0xFFFFFFFF
  @max_payload 65_536

  @spec encode(t()) :: {:ok, binary()} | {:error, :invalid_wire_frame}
  def encode(%__MODULE__{} = f) do
    if valid?(f) do
      config = if f.config_epoch == :unknown, do: @unknown, else: f.config_epoch

      {:ok,
       <<"MEX1", 1, 0, 48::unsigned-big-16, f.stream_number::unsigned-big-32,
         f.source_epoch::unsigned-big-32, config::unsigned-big-32, f.sequence::unsigned-big-64,
         f.first_sample::unsigned-big-64, f.sample_count::unsigned-big-32,
         byte_size(f.payload)::unsigned-big-32, 0::unsigned-big-32, f.payload::binary>>}
    else
      {:error, :invalid_wire_frame}
    end
  end

  def encode(_), do: {:error, :invalid_wire_frame}

  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_wire_frame}
  def decode(
        <<"MEX1", 1, 0, 48::unsigned-big-16, handle::unsigned-big-32, epoch::unsigned-big-32,
          config::unsigned-big-32, sequence::unsigned-big-64, first::unsigned-big-64,
          count::unsigned-big-32, size::unsigned-big-32, 0::unsigned-big-32, payload::binary>>
      )
      when size == byte_size(payload) and size <= @max_payload do
    f = %__MODULE__{
      stream_number: handle,
      source_epoch: epoch,
      config_epoch: if(config == @unknown, do: :unknown, else: config),
      sequence: sequence,
      first_sample: first,
      sample_count: count,
      payload: payload
    }

    if valid?(f), do: {:ok, f}, else: {:error, :invalid_wire_frame}
  end

  def decode(_), do: {:error, :invalid_wire_frame}

  defp valid?(f) do
    R.uint?(f.stream_number, @unknown) and R.uint?(f.source_epoch, @unknown) and
      R.config?(f.config_epoch) and
      R.uint?(f.sequence, @u64) and R.uint?(f.first_sample, @u64) and
      valid_sample_range?(f) and
      is_binary(f.payload) and byte_size(f.payload) in 1..@max_payload
  end

  defp valid_sample_range?(f) do
    R.uint?(f.sample_count, @unknown) and f.sample_count > 0 and
      f.first_sample + f.sample_count <= @u64
  end
end
