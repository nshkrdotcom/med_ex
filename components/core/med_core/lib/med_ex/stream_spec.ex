defmodule MedEx.StreamSpec do
  @moduledoc "Immutable regular-waveform descriptor. Unknown calibration is never a unit scale."
  alias MedEx.ContractRules, as: R

  @enforce_keys [
    :acquisition_id,
    :source_ref,
    :boot_id,
    :stream_id,
    :source_epoch,
    :descriptor_ref,
    :modality,
    :encoding,
    :channels,
    :sample_rate,
    :capabilities
  ]
  defstruct @enforce_keys ++
              [
                schema_version: 1,
                layout: :interleaved,
                clock: :unknown,
                source_processing: :unknown
              ]

  @type channel :: %{
          id: String.t(),
          label: String.t(),
          unit: :unknown | String.t(),
          calibration:
            :unknown
            | %{
                zero: integer(),
                scale_num: integer(),
                scale_den: pos_integer(),
                reference: String.t()
              }
        }
  @type t :: %__MODULE__{
          schema_version: 1,
          acquisition_id: String.t(),
          source_ref: String.t(),
          boot_id: String.t(),
          stream_id: String.t(),
          source_epoch: non_neg_integer(),
          descriptor_ref: String.t(),
          modality: String.t(),
          encoding: :s16le | :s24le | :s32le,
          channels: [channel()],
          sample_rate: {pos_integer(), pos_integer()},
          layout: :interleaved,
          clock: :unknown | map(),
          source_processing: :unknown | [map()],
          capabilities: map()
        }

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = s) do
    cond do
      s.schema_version != 1 or s.layout != :interleaved ->
        {:error, :unsupported_descriptor}

      not Enum.all?([s.acquisition_id, s.source_ref, s.boot_id, s.stream_id], &R.id?/1) ->
        {:error, :invalid_identity}

      not R.uint?(s.source_epoch, 0xFFFFFFFF) or not R.digest?(s.descriptor_ref) ->
        {:error, :invalid_revision}

      not R.id?(s.modality) or
          not Regex.match?(~r/\A[a-z][a-z0-9_.-]*:[a-z][a-z0-9_.-]*\z/, s.modality) ->
        {:error, :invalid_modality}

      s.encoding not in [:s16le, :s24le, :s32le] ->
        {:error, :unsupported_encoding}

      not R.rational?(s.sample_rate) ->
        {:error, :invalid_sample_rate}

      not channels?(s.channels) ->
        {:error, :invalid_channels}

      not capabilities?(s.capabilities, s.encoding) ->
        {:error, :invalid_capabilities}

      not clock?(s.clock) ->
        {:error, :invalid_clock}

      s.source_processing != :unknown and not R.list?(s.source_processing, 32, &R.fact?/1) ->
        {:error, :invalid_processing}

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, :invalid_descriptor}
  def bytes_per_value(:s16le), do: 2
  def bytes_per_value(:s24le), do: 3
  def bytes_per_value(:s32le), do: 4
  def bytes_per_value(_), do: {:error, :unsupported_encoding}

  defp channels?(xs) do
    R.list?(xs, 32, &channel?/1) and xs != [] and
      length(Enum.uniq_by(xs, & &1.id)) == length(xs)
  end

  defp channel?(%{id: id, label: label, unit: unit, calibration: calibration} = m)
       when map_size(m) == 4 do
    R.id?(id) and R.id?(label) and (unit == :unknown or R.id?(unit)) and
      calibration?(calibration, unit)
  end

  defp channel?(_), do: false
  defp calibration?(:unknown, _unit), do: true

  defp calibration?(%{zero: z, scale_num: n, scale_den: d, reference: ref} = m, unit)
       when map_size(m) == 4 do
    R.id?(unit) and R.signed?(z) and R.signed?(n) and n != 0 and
      R.uint?(d, 0xFFFFFFFFFFFFFFFF) and d > 0 and R.id?(ref)
  end

  defp calibration?(_, _), do: false

  defp capabilities?(
         %{
           encodings: enc,
           max_frame_samples: count,
           max_payload_bytes: bytes,
           replay: replay,
           commands: commands
         } = m,
         encoding
       )
       when map_size(m) == 5 do
    R.list?(enc, 3, &(&1 in [:s16le, :s24le, :s32le])) and encoding in enc and
      R.uint?(count, 0xFFFFFFFF) and count > 0 and R.uint?(bytes, 65_536) and bytes > 0 and
      replay in [:none, :durable_spool] and R.list?(commands, 32, &command?/1)
  end

  defp capabilities?(_, _), do: false
  defp command?(v), do: R.id?(v) and Regex.match?(~r/\A[a-z][a-z0-9_.:-]*\z/, v)
  defp clock?(:unknown), do: true

  defp clock?(
         %{
           domain_id: id,
           boot_id: boot,
           generation: generation,
           tick_rate: rate,
           uncertainty_ticks: uncertainty
         } = m
       )
       when map_size(m) == 5 do
    R.id?(id) and R.id?(boot) and R.uint?(generation, 0xFFFFFFFFFFFFFFFF) and
      R.rational?(rate) and (uncertainty == :unknown or R.uint?(uncertainty, 0xFFFFFFFFFFFFFFFF))
  end

  defp clock?(_), do: false
end
