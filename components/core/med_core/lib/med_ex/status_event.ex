defmodule MedEx.StatusEvent do
  @moduledoc "Technical observation. A source alarm ID or a sequence number does not establish a waveform boundary."
  alias MedEx.ContractRules, as: R

  @enforce_keys ~w(event_id acquisition_id source_ref boot_id stream_id source_epoch descriptor_ref sequence code observed_interval)a
  defstruct @enforce_keys ++
              [
                schema_version: 1,
                source_alarm_id: nil,
                state: :unknown,
                acknowledgement: :unknown
              ]

  def validate(%__MODULE__{} = e) do
    valid =
      e.schema_version == 1 and
        Enum.all?(
          [e.event_id, e.acquisition_id, e.source_ref, e.boot_id, e.stream_id, e.code],
          &R.id?/1
        ) and
        R.digest?(e.descriptor_ref) and R.uint?(e.source_epoch, 0xFFFFFFFF) and
        R.uint?(e.sequence, 0xFFFFFFFFFFFFFFFF) and interval?(e.observed_interval) and
        (is_nil(e.source_alarm_id) or R.id?(e.source_alarm_id)) and R.scalar?(e.state) and
        R.scalar?(e.acknowledgement)

    if valid, do: :ok, else: {:error, :invalid_status}
  end

  def validate(_), do: {:error, :invalid_status}
  defp interval?(:unknown), do: true

  defp interval?(%{clock_id: id, earliest: a, latest: b} = interval),
    do: map_size(interval) == 3 and R.id?(id) and R.signed?(a) and R.signed?(b) and a <= b

  defp interval?(_), do: false
end
