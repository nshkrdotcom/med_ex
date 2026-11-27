defmodule MedEx.Serialization do
  @moduledoc """
  MEJ1 representation of stream descriptors, indexes and receipts. Counter fields
  are decimal strings, rational rates are ordered pairs and enums are strings.
  Decode using the field's declared type. Arbitrary protocol payloads use Base64.
  """
  alias MedEx.{
    CanonicalJSON,
    MeasurementEvent,
    SegmentRef,
    StatusEvent,
    StreamSpec
  }

  @max_index_entries max(
                       MedEx.RecordingLimits.maximum().spans,
                       MedEx.RecordingLimits.maximum().generations
                     )

  def bytes(value), do: value |> to_map() |> CanonicalJSON.encode()
  def digest(value), do: sha256(bytes(value))
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def descriptor_ref(%StreamSpec{} = s), do: to_map(s) |> Map.delete("descriptor_ref") |> digest()

  def to_map(%MedEx.Receipt{} = receipt), do: MedEx.Receipt.to_map(receipt)

  def to_map(%MeasurementEvent{} = e) do
    e
    |> Map.from_struct()
    |> Map.update!(:device_status, fn
      :unknown -> :unknown
      values -> Map.new(values, fn {k, v} -> {k, scalar(v)} end)
    end)
    |> Map.update!(:raw, fn
      {:bytes, bytes} -> %{"base64" => Base.encode64(bytes)}
      {:sha256, sha} -> %{"sha256" => sha}
    end)
    |> to_map()
  end

  def to_map(%StatusEvent{} = event) do
    event
    |> Map.from_struct()
    |> Map.update!(:state, &scalar/1)
    |> Map.update!(:acknowledgement, &scalar/1)
    |> to_map()
  end

  def to_map(%MedEx.IntegritySpan{} = span) do
    span
    |> Map.from_struct()
    |> Map.update!(:context, &Map.new(&1, fn {k, v} -> {k, scalar(v)} end))
    |> to_map()
  end

  def to_map(%{name: name, origin: origin, value: v} = fact) when map_size(fact) == 3 do
    %{"name" => name, "origin" => to_map(origin), "value" => scalar(v)}
  end

  def to_map(%_{} = value), do: value |> Map.from_struct() |> to_map()

  def to_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, v}, acc ->
      unless is_atom(key) or is_binary(key), do: raise(ArgumentError, "invalid MEJ1 key")
      k = to_string(key)
      if Map.has_key?(acc, k), do: raise(ArgumentError, "duplicate MEJ1 key")
      Map.put(acc, k, to_map(v))
    end)
  end

  def to_map(value) when is_list(value), do: Enum.map(value, &to_map/1)
  def to_map(value) when is_tuple(value), do: value |> Tuple.to_list() |> to_map()
  def to_map(value) when is_boolean(value) or is_nil(value) or is_binary(value), do: value
  def to_map(value) when is_integer(value), do: Integer.to_string(value)
  def to_map(value) when is_atom(value), do: Atom.to_string(value)

  defp scalar(:unknown), do: %{"unknown" => true}
  defp scalar(value) when is_integer(value), do: %{"integer" => Integer.to_string(value)}
  defp scalar(value), do: value
  def unscalar!(%{"unknown" => true} = v) when map_size(v) == 1, do: :unknown
  def unscalar!(%{"integer" => n} = v) when map_size(v) == 1, do: integer!(n)
  def unscalar!(v) when is_binary(v) or is_boolean(v), do: v

  def status_event(map) do
    event = %StatusEvent{
      schema_version: integer!(map["schema_version"]),
      event_id: map["event_id"],
      acquisition_id: map["acquisition_id"],
      source_ref: map["source_ref"],
      boot_id: map["boot_id"],
      stream_id: map["stream_id"],
      source_epoch: integer!(map["source_epoch"]),
      descriptor_ref: map["descriptor_ref"],
      sequence: integer!(map["sequence"]),
      code: map["code"],
      observed_interval: observed_interval!(map["observed_interval"]),
      source_alarm_id: map["source_alarm_id"],
      state: unscalar!(map["state"]),
      acknowledgement: unscalar!(map["acknowledgement"])
    }

    if StatusEvent.validate(event) == :ok and to_map(event) == map,
      do: {:ok, event},
      else: {:error, :invalid_status}
  rescue
    _ in [ArgumentError, FunctionClauseError, BadMapError] -> {:error, :invalid_status}
  end

  defp observed_interval!("unknown"), do: :unknown

  defp observed_interval!(%{"clock_id" => id, "earliest" => first, "latest" => last}),
    do: %{clock_id: id, earliest: integer!(first), latest: integer!(last)}

  def segment_ref(map) do
    segment = %SegmentRef{
      key: map["key"],
      sha256: map["sha256"],
      descriptor_ref: map["descriptor_ref"],
      byte_size: integer!(map["byte_size"]),
      first_sample: integer!(map["first_sample"]),
      end_sample: integer!(map["end_sample"]),
      first_sequence: integer!(map["first_sequence"]),
      next_sequence: integer!(map["next_sequence"]),
      config_epoch:
        if(map["config_epoch"] == "unknown", do: :unknown, else: integer!(map["config_epoch"]))
    }

    if SegmentRef.validate(segment) == :ok and to_map(segment) == map,
      do: {:ok, segment},
      else: {:error, :invalid_segment_ref}
  rescue
    _ in [ArgumentError, FunctionClauseError, BadMapError] -> {:error, :invalid_segment_ref}
  end

  def stream_spec(map) do
    s =
      struct!(StreamSpec,
        acquisition_id: map["acquisition_id"],
        source_ref: map["source_ref"],
        boot_id: map["boot_id"],
        stream_id: map["stream_id"],
        modality: map["modality"],
        descriptor_ref: map["descriptor_ref"],
        schema_version: integer!(map["schema_version"]),
        layout: enum!(map["layout"], [:interleaved]),
        source_epoch: integer!(map["source_epoch"]),
        sample_rate: rate!(map["sample_rate"]),
        encoding: encoding!(map["encoding"]),
        channels: Enum.map(map["channels"], &channel!/1),
        capabilities: caps!(map["capabilities"]),
        clock: clock!(map["clock"]),
        source_processing: facts!(map["source_processing"])
      )

    with :ok <- StreamSpec.validate(s),
         true <- to_map(s) == map do
      {:ok, s}
    else
      _ -> {:error, :invalid_descriptor}
    end
  rescue
    _ in [ArgumentError, FunctionClauseError, KeyError, Protocol.UndefinedError, BadMapError] ->
      {:error, :invalid_descriptor}
  end

  @doc "Restore a validated sparse event, preserving exact decimal and raw payload identity."
  def measurement(map) do
    e =
      struct!(MeasurementEvent,
        schema_version: integer!(map["schema_version"]),
        event_id: map["event_id"],
        acquisition_id: map["acquisition_id"],
        source_ref: map["source_ref"],
        boot_id: map["boot_id"],
        stream_id: map["stream_id"],
        source_epoch: integer!(map["source_epoch"]),
        descriptor_ref: map["descriptor_ref"],
        gateway_sequence: integer!(map["gateway_sequence"]),
        source_record_id: map["source_record_id"],
        metrics: Map.new(map["metrics"], &metric!/1),
        raw: raw!(map["raw"]),
        device_status: status!(map["device_status"]),
        provenance: facts!(map["provenance"]),
        device_time: time!(map["device_time"]),
        receipt_time: time!(map["receipt_time"])
      )

    if MeasurementEvent.validate(e) == :ok and to_map(e) == map,
      do: {:ok, e},
      else: {:error, :invalid_measurement}
  rescue
    _ in [ArgumentError, FunctionClauseError, KeyError, Protocol.UndefinedError, BadMapError] ->
      {:error, :invalid_measurement}
  end

  defp metric!({key, ["missing", reason]}), do: {key, {:missing, reason}}

  defp metric!({key, ["value", m, e, unit]}),
    do: {key, {:value, integer!(m), integer!(e), unknown(unit)}}

  defp raw!(%{"base64" => bytes}) when is_binary(bytes) and byte_size(bytes) <= 21_848,
    do: {:bytes, Base.decode64!(bytes)}

  defp raw!(%{"sha256" => digest}), do: {:sha256, digest}
  defp status!("unknown"), do: :unknown
  defp status!(m), do: Map.new(m, fn {key, v} -> {key, unscalar!(v)} end)
  defp time!("unknown"), do: :unknown

  defp time!(m),
    do: %{
      clock_id: m["clock_id"],
      boot_id: m["boot_id"],
      ticks: integer!(m["ticks"]),
      uncertainty_ticks:
        if(m["uncertainty_ticks"] == "unknown",
          do: :unknown,
          else: integer!(m["uncertainty_ticks"])
        )
    }

  def integrity_span(map) when is_map(map) do
    span = %MedEx.IntegritySpan{
      stream_id: map["stream_id"],
      source_epoch: integer!(map["source_epoch"]),
      code:
        enum!(map["code"], [
          :source_gap,
          :configuration_unknown,
          :duplicate_conflict,
          :clock_unavailable,
          :device_status_invalid,
          :source_processing_unverified
        ]),
      source: map["source"],
      first_sample: if(is_nil(map["first_sample"]), do: nil, else: integer!(map["first_sample"])),
      end_sample: if(is_nil(map["end_sample"]), do: nil, else: integer!(map["end_sample"])),
      event_ids: map["event_ids"],
      record_refs: map["record_refs"],
      context: Map.new(map["context"], fn {k, v} -> {k, unscalar!(v)} end)
    }

    if MedEx.IntegritySpan.validate(span) == :ok and to_map(span) == map,
      do: {:ok, span},
      else: {:error, :invalid_integrity_span}
  rescue
    _ in [ArgumentError, FunctionClauseError, BadMapError, KeyError, Protocol.UndefinedError] ->
      {:error, :invalid_integrity_span}
  end

  def integrity_span(_), do: {:error, :invalid_integrity_span}

  def gap(map) when is_map(map) do
    with {:ok, span} <- integrity_span(map["span"]) do
      gap = %{
        id: map["id"],
        span: span,
        first_sequence: integer!(map["first_sequence"]),
        next_sequence: integer!(map["next_sequence"]),
        irreversible: map["irreversible"]
      }

      if to_map(gap) == map, do: {:ok, gap}, else: {:error, :invalid_gap}
    end
  rescue
    _ in [ArgumentError, FunctionClauseError, BadMapError, KeyError] -> {:error, :invalid_gap}
  end

  def gap(_), do: {:error, :invalid_gap}

  def stream_index(map) when is_map(map) do
    with {:ok, stream} <- stream_spec(map["stream"]),
         {:ok, segments} <- parse_list(map["segments"], &segment_ref/1),
         {:ok, spans} <- parse_list(map["spans"], &integrity_span/1),
         {:ok, gaps} <- parse_list(map["gaps"], &gap/1) do
      index = %MedEx.StreamIndex{
        schema_version: integer!(map["schema_version"]),
        stream: stream,
        segments: segments,
        spans: spans,
        gaps: gaps,
        terminal: enum!(map["terminal"], [:finished, :interrupted, :failed]),
        terminal_reason: map["terminal_reason"],
        fence: map["fence"],
        journal_id: map["journal_id"],
        journal_generation: integer!(map["journal_generation"]),
        journal_digest: map["journal_digest"],
        next_sequence: integer!(map["next_sequence"]),
        next_sample: integer!(map["next_sample"]),
        predecessor: map["predecessor"]
      }

      if MedEx.StreamIndex.validate(index) == :ok and to_map(index) == map,
        do: {:ok, index},
        else: {:error, :invalid_stream_index}
    end
  rescue
    _ in [ArgumentError, FunctionClauseError, BadMapError, KeyError] ->
      {:error, :invalid_stream_index}
  end

  def stream_index(_), do: {:error, :invalid_stream_index}

  defp parse_list(list, parser) when is_list(list) and length(list) <= @max_index_entries do
    Enum.reduce_while(list, {:ok, []}, fn raw, {:ok, values} ->
      case parser.(raw) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp parse_list(_, _), do: {:error, :invalid_list}

  def integer!(n) when is_binary(n) and byte_size(n) in 1..21 do
    case Integer.parse(n) do
      {i, ""} -> if Integer.to_string(i) == n, do: i, else: raise(ArgumentError)
      _ -> raise ArgumentError
    end
  end

  def enum!(s, values), do: Enum.find(values, &(Atom.to_string(&1) == s)) || raise(ArgumentError)
  defp encoding!(s), do: enum!(s, [:s16le, :s24le, :s32le])
  defp rate!([n, d]), do: {integer!(n), integer!(d)}

  defp channel!(m),
    do: %{
      id: m["id"],
      label: m["label"],
      unit: unknown(m["unit"]),
      calibration: calibration!(m["calibration"])
    }

  defp unknown("unknown"), do: :unknown
  defp unknown(v), do: v
  defp calibration!("unknown"), do: :unknown

  defp calibration!(m),
    do: %{
      zero: integer!(m["zero"]),
      scale_num: integer!(m["scale_num"]),
      scale_den: integer!(m["scale_den"]),
      reference: m["reference"]
    }

  defp caps!(m),
    do: %{
      encodings: Enum.map(m["encodings"], &encoding!/1),
      commands: m["commands"],
      replay: enum!(m["replay"], [:none, :durable_spool]),
      max_frame_samples: integer!(m["max_frame_samples"]),
      max_payload_bytes: integer!(m["max_payload_bytes"])
    }

  defp clock!("unknown"), do: :unknown

  defp clock!(m),
    do: %{
      domain_id: m["domain_id"],
      boot_id: m["boot_id"],
      generation: integer!(m["generation"]),
      tick_rate: rate!(m["tick_rate"]),
      uncertainty_ticks:
        if(m["uncertainty_ticks"] == "unknown",
          do: :unknown,
          else: integer!(m["uncertainty_ticks"])
        )
    }

  defp facts!("unknown"), do: :unknown

  defp facts!(list),
    do:
      Enum.map(list, fn m ->
        %{
          name: m["name"],
          origin: enum!(m["origin"], [:observed, :claimed]),
          value: unscalar!(m["value"])
        }
      end)
end
