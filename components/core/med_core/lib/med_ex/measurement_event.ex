defmodule MedEx.MeasurementEvent do
  @moduledoc "Sparse exact decimal measurements with explicit missing values and raw provenance."
  alias MedEx.ContractRules, as: R

  @enforce_keys [
    :event_id,
    :acquisition_id,
    :source_ref,
    :boot_id,
    :stream_id,
    :source_epoch,
    :gateway_sequence,
    :descriptor_ref,
    :metrics,
    :raw
  ]
  defstruct @enforce_keys ++
              [
                schema_version: 1,
                source_record_id: nil,
                device_status: :unknown,
                device_time: :unknown,
                receipt_time: :unknown,
                provenance: []
              ]

  @type metric :: {:value, integer(), -18..18, :unknown | String.t()} | {:missing, String.t()}
  @type t :: %__MODULE__{
          schema_version: 1,
          event_id: String.t(),
          acquisition_id: String.t(),
          source_ref: String.t(),
          boot_id: String.t(),
          stream_id: String.t(),
          source_epoch: non_neg_integer(),
          gateway_sequence: non_neg_integer(),
          descriptor_ref: String.t(),
          metrics: %{String.t() => metric()},
          raw: {:bytes, binary()} | {:sha256, String.t()},
          source_record_id: String.t() | nil,
          device_status: :unknown | map(),
          device_time: :unknown | map(),
          provenance: [map()]
        }
  def validate(%__MODULE__{} = e) do
    valid =
      e.schema_version == 1 and
        Enum.all?([e.event_id, e.acquisition_id, e.source_ref, e.boot_id, e.stream_id], &R.id?/1) and
        R.uint?(e.source_epoch, 0xFFFFFFFF) and R.uint?(e.gateway_sequence, 0xFFFFFFFFFFFFFFFF) and
        R.digest?(e.descriptor_ref) and (e.source_record_id == nil or R.id?(e.source_record_id)) and
        is_map(e.metrics) and map_size(e.metrics) in 1..32 and Enum.all?(e.metrics, &metric?/1) and
        raw?(e.raw) and
        status?(e.device_status) and time?(e.device_time) and time?(e.receipt_time) and
        R.list?(e.provenance, 32, &R.fact?/1)

    if valid, do: :ok, else: {:error, :invalid_measurement}
  end

  def validate(_), do: {:error, :invalid_measurement}
  defp metric?({code, {:missing, reason}}), do: R.key?(code) and R.id?(reason)

  defp metric?({code, {:value, mantissa, exponent, unit}}) do
    R.key?(code) and is_integer(mantissa) and abs(mantissa) <= 0xFFFFFFFFFFFFFFFF and
      is_integer(exponent) and exponent in -18..18 and (unit == :unknown or R.id?(unit))
  end

  defp metric?(_), do: false
  defp raw?({:bytes, b}), do: is_binary(b) and byte_size(b) in 1..16_384
  defp raw?({:sha256, digest}), do: R.digest?(digest)
  defp raw?(_), do: false
  defp status?(:unknown), do: true

  defp status?(values) when is_map(values) and map_size(values) <= 32,
    do: Enum.all?(values, fn {key, value} -> R.key?(key) and R.scalar?(value) end)

  defp status?(_), do: false
  defp time?(:unknown), do: true

  defp time?(%{clock_id: id, boot_id: boot, ticks: ticks, uncertainty_ticks: uncertainty}) do
    R.id?(id) and R.id?(boot) and is_integer(ticks) and abs(ticks) <= 0xFFFFFFFFFFFFFFFF and
      (uncertainty == :unknown or R.uint?(uncertainty, 0xFFFFFFFFFFFFFFFF))
  end

  defp time?(_), do: false
end
