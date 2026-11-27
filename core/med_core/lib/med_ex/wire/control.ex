defmodule MedEx.Wire.Control do
  @moduledoc "The single revision-2 bounded acquisition request and reply codec."
  alias MedEx.{ContractRules, Receipt, Serialization}
  @schema "medex.acquisition.v2"
  @max_json 16_384
  @base ~w(binding operation_id)
  # Required keys and the complete per-operation key inventory. No extension keys.
  @messages %{
    "hello" =>
      {~w(operation_id api_revision acquisition encounter profile boot descriptors),
       ~w(operation_id api_revision acquisition encounter profile boot descriptors creation max_credit_frames max_credit_bytes)},
    "admitted" =>
      {~w(binding api_revision credit_frames credit_bytes authority_ms),
       ~w(binding operation_id api_revision lease credit_frames credit_bytes authority_ms phase stream_numbers descriptors handoff)},
    "open_stream" =>
      {~w(binding operation_id stream descriptor_ref),
       @base ++
         ~w(acquisition generation lease stream descriptor_ref max_credit_frames max_credit_bytes)},
    "gap" =>
      {@base ++ ~w(id first end first_sequence next_sequence irreversible cause),
       @base ++ ~w(id first end first_sequence next_sequence irreversible cause stream)},
    "checkpoint" => {@base, @base},
    "finish" => {@base ++ ~w(sequence sample), @base ++ ~w(sequence sample interruption)},
    "finish_acquisition" => {@base, @base ++ ~w(count digest)},
    "collection_finish" => {@base ++ ~w(count digest), @base ++ ~w(count digest)},
    "heartbeat" => {@base ++ ~w(nonce), @base ++ ~w(nonce boot)},
    "heartbeat_reply" =>
      {@base ++ ~w(nonce boot generation remaining_ms),
       @base ++
         ~w(nonce boot generation remaining_ms command_remaining_ms command stop_requested phase)},
    "command" =>
      {@base ++ ~w(nonce boot generation remaining_ms command_remaining_ms command),
       @base ++ ~w(nonce boot generation remaining_ms command_remaining_ms command stop_requested)},
    "state_query" =>
      {@base ++ ~w(nonce boot generation remaining_ms command),
       @base ++
         ~w(nonce boot generation remaining_ms command_remaining_ms command stop_requested id fingerprint)},
    "readback" =>
      {@base ++ ~w(nonce boot generation remaining_ms command),
       @base ++ ~w(nonce boot generation remaining_ms command_remaining_ms command stop_requested)},
    "continue" =>
      {@base ++ ~w(nonce boot generation remaining_ms),
       @base ++
         ~w(nonce boot generation remaining_ms command_remaining_ms command stop_requested phase)},
    "stop" =>
      {@base ++ ~w(nonce boot generation remaining_ms),
       @base ++ ~w(nonce boot generation remaining_ms stop_requested phase)},
    "measurement" => {@base ++ ~w(event), @base ++ ~w(event fingerprint)},
    "result" =>
      {@base,
       @base ++
         ~w(result id fingerprint boot boot_id target generation status outcome epoch expected_epoch application applied_sample observed_at gain reason)},
    "result_saved" => {@base, @base ++ ~w(id fingerprint status)},
    "probe" => {@base ++ ~w(stream), @base ++ ~w(stream id sent_at)},
    "probe_reply" => {@base ++ ~w(id d2 d3), @base ++ ~w(id d2 d3)},
    "anchor" =>
      {@base ++ ~w(stream method sample_index tick error_us),
       @base ++ ~w(stream method sample_index tick error_us)},
    "status" => {@base, @base ++ ~w(state repeat_of event event_id reason)},
    "recorded" => {@base, @base ++ ~w(id fingerprint state)},
    "open_monitor" => {@base, @base ++ ~w(acquisition generation lease stream descriptor_ref)},
    "monitor_credit" => {@base, @base ++ ~w(credit_frames credit_bytes)},
    "close_monitor" => {@base, @base},
    "accepted" => {@base ++ ~w(receipt), @base ++ ~w(receipt transport_sha256 fingerprint)},
    "durable" =>
      {@base, @base ++ ~w(receipt event_id fingerprint handoff credit_frames credit_bytes)},
    "stream_finished" =>
      {@base ++ ~w(receipt index_digest terminal),
       @base ++ ~w(receipt index_digest terminal handoff credit_frames credit_bytes)},
    "sealed" => {@base ++ ~w(digest), @base ++ ~w(digest)},
    "inventory_pending" => {@base, @base ++ ~w(count digest)},
    "replay" => {@base ++ ~w(receipt), @base ++ ~w(receipt)},
    "refused" => {@base ++ ~w(reason), @base ++ ~w(reason retry fingerprint transport_sha256)},
    "error" => {~w(reason), @base ++ ~w(reason retry)}
  }
  @counters ~w(generation sequence sample first end first_sequence next_sequence count sample_index tick error_us d2 d3 epoch expected_epoch applied_sample observed_at)
  @identifiers ~w(acquisition encounter boot operation_id connection stream event_id id nonce repeat_of target)

  def schema, do: @schema

  def decode(bytes, allowed)
      when is_binary(bytes) and byte_size(bytes) <= @max_json and is_list(allowed) do
    decoders = [
      object_start: fn _ -> %{} end,
      object_push: fn key, value, object ->
        if Map.has_key?(object, key), do: throw(:duplicate_protocol_key)
        Map.put(object, key, value)
      end,
      object_finish: fn object, parent -> {object, parent} end
    ]

    case JSON.decode(bytes, nil, decoders) do
      {%{"schema" => @schema, "type" => type} = message, nil, remaining} ->
        decode_message(type, message, remaining, allowed)

      _ ->
        {:error, :invalid_message}
    end
  rescue
    _ -> {:error, :invalid_message}
  catch
    :duplicate_protocol_key -> {:error, :duplicate_key}
  end

  def decode(_, _), do: {:error, :message_limit}

  defp decode_message(type, message, remaining, allowed) do
    cond do
      not is_binary(type) or type not in allowed -> {:error, :unsupported_message}
      String.trim(remaining) != "" -> {:error, :invalid_message}
      true -> validate(message)
    end
  end

  def encode(type, fields) when is_binary(type) and is_map(fields) do
    if Map.has_key?(fields, "schema") or Map.has_key?(fields, "type") do
      {:error, :reserved_field}
    else
      message = Map.merge(fields, %{"schema" => @schema, "type" => type})

      with {:ok, ^message} <- validate(message), do: encode_message(message)
    end
  rescue
    _ -> {:error, :invalid_message}
  end

  def encode(_, _), do: {:error, :invalid_message}

  defp encode_message(message) do
    bytes = JSON.encode!(message)
    if byte_size(bytes) <= @max_json, do: {:ok, bytes}, else: {:error, :message_limit}
  end

  defp validate(%{"type" => type} = message) do
    case Map.fetch(@messages, type) do
      {:ok, {required, allowed}} ->
        valid =
          Enum.all?(required, &Map.has_key?(message, &1)) and
            Enum.all?(Map.keys(message), &(&1 in ["schema", "type" | allowed])) and
            Enum.all?(message, &field?/1) and special?(type, message)

        if valid, do: {:ok, message}, else: {:error, :invalid_message}

      :error ->
        {:error, :unsupported_message}
    end
  end

  defp field?({key, value}) when key in @counters, do: match?({:ok, _}, uint64(value))
  defp field?({key, value}) when key in @identifiers, do: identifier?(value)
  defp field?({"binding", value}), do: binding?(value)
  defp field?({"receipt", value}), do: match?({:ok, _}, Receipt.parse(value))
  defp field?({"api_revision", value}), do: value == 2

  defp field?({key, value}) when key in ~w(max_credit_frames credit_frames),
    do: is_integer(value) and value in 1..15

  defp field?({key, value}) when key in ~w(max_credit_bytes credit_bytes),
    do: is_integer(value) and value in 1..262_144

  defp field?({key, value}) when key in ~w(authority_ms remaining_ms command_remaining_ms),
    do: is_integer(value) and value in 0..30_000

  defp field?({key, value})
       when key in ~w(descriptor_ref fingerprint transport_sha256 index_digest digest),
       do: ContractRules.digest?(value)

  defp field?({"profile", value}), do: value in ~w(paired_exam plx_spot_check browser_microphone)

  defp field?({key, value}) when key in ~w(lease creation),
    do: is_binary(value) and byte_size(value) in 16..512

  defp field?({key, value}) when key in ~w(irreversible stop_requested), do: is_boolean(value)
  defp field?({"terminal", value}), do: value in ~w(finished interrupted failed)

  defp field?({"phase", value}),
    do: value in ~w(capturing draining finalizing complete interrupted sealed)

  defp field?({"event", value}),
    do:
      match?({:ok, _}, Serialization.measurement(value)) or
        match?({:ok, _}, Serialization.status_event(value))

  defp field?({"descriptors", value}),
    do:
      is_map(value) and map_size(value) <= 3 and
        Enum.all?(value, fn {key, descriptor} ->
          key in ~w(audio ecg monitor) and match?({:ok, _}, Serialization.stream_spec(descriptor))
        end)

  defp field?({"stream_numbers", value}),
    do:
      is_map(value) and map_size(value) in 1..3 and
        Enum.all?(value, fn {k, v} -> k in ~w(audio ecg monitor) and v in 1..3 end)

  defp field?({"handoff", value}) when is_map(value) and map_size(value) == 4 do
    value["asserted_by"] == "authenticated_host" and
      Enum.all?(~w(previous successor imported), &Receipt.durable?(value[&1]))
  end

  defp field?({"handoff", _}), do: false

  defp field?({key, value}) when key in ~w(command result application),
    do: is_map(value) and bounded?(value, 0)

  defp field?({key, value}) when key in ~w(schema type), do: is_binary(value)
  defp field?({_, value}), do: bounded?(value, 0)

  defp special?("durable", m),
    do:
      (Map.has_key?(m, "receipt") and Receipt.durable?(elem(Receipt.parse(m["receipt"]), 1))) or
        (identifier?(m["event_id"]) and ContractRules.digest?(m["fingerprint"]) and
           not Map.has_key?(m, "receipt"))

  defp special?("stream_finished", m), do: Receipt.durable?(elem(Receipt.parse(m["receipt"]), 1))
  defp special?("gap", m), do: m["irreversible"] == true

  defp special?(type, m) when type in ~w(open_stream open_monitor) do
    Enum.all?(~w(acquisition generation), fn key ->
      not Map.has_key?(m, key) or m[key] == m["binding"][key]
    end)
  end

  defp special?(_, _), do: true

  defp binding?(b) when is_map(b) do
    required = ~w(acquisition profile generation connection)

    Enum.all?(required, &Map.has_key?(b, &1)) and
      Enum.all?(Map.keys(b), &(&1 in (required ++ ~w(stream fence journal_id)))) and
      Enum.all?(b, fn
        {"profile", p} -> p in ~w(paired_exam plx_spot_check browser_microphone)
        {"generation", g} -> match?({:ok, _}, uint64(g))
        {_, v} -> identifier?(v)
      end)
  end

  defp binding?(_), do: false

  defp identifier?(v),
    do: is_binary(v) and byte_size(v) in 1..96 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, v)

  defp bounded?(_, depth) when depth > 8, do: false
  defp bounded?(v, _) when is_binary(v), do: byte_size(v) <= 8192 and String.valid?(v)
  defp bounded?(v, _) when is_boolean(v) or is_nil(v), do: true
  defp bounded?(v, _) when is_integer(v), do: v >= -2_147_483_648 and v <= 2_147_483_647

  defp bounded?(v, depth) when is_list(v),
    do: length(v) <= 256 and Enum.all?(v, &bounded?(&1, depth + 1))

  defp bounded?(v, depth) when is_map(v),
    do:
      map_size(v) <= 64 and
        Enum.all?(v, fn {k, val} ->
          is_binary(k) and byte_size(k) <= 96 and bounded?(val, depth + 1)
        end)

  defp bounded?(_, _), do: false

  def uint64(value) when is_binary(value) and byte_size(value) in 1..20 do
    case Integer.parse(value) do
      {n, ""} when n >= 0 and n <= 0xFFFFFFFFFFFFFFFF ->
        if Integer.to_string(n) == value, do: {:ok, n}, else: {:error, :invalid_uint64}

      _ ->
        {:error, :invalid_uint64}
    end
  end

  def uint64(_), do: {:error, :invalid_uint64}
end
