defmodule MedEx.Wire.Control do
  @moduledoc """
  Bounded JSON device-protocol envelope. The host supplies the allowed operations
  for a connection/phase and validates each operation's required fields against
  its authenticated reservation. Nested duplicate keys fail before dispatch.
  """
  @schema "medex.device.v1"
  @max_json 16_384
  @type message :: %{required(binary()) => term()}
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
      {%{"schema" => @schema, "type" => type} = m, nil, remaining} ->
        if is_binary(type) and type in allowed and String.trim(remaining) == "",
          do: {:ok, m},
          else: {:error, :unsupported_message}

      _ ->
        {:error, :invalid_message}
    end
  catch
    :duplicate_protocol_key -> {:error, :duplicate_key}
  end

  def decode(_, _), do: {:error, :message_limit}

  def encode(type, fields) when is_binary(type) and is_map(fields) do
    if Map.has_key?(fields, "schema") or Map.has_key?(fields, "type") do
      {:error, :reserved_field}
    else
      bytes = fields |> Map.merge(%{"schema" => @schema, "type" => type}) |> JSON.encode!()
      if byte_size(bytes) <= @max_json, do: {:ok, bytes}, else: {:error, :message_limit}
    end
  end

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
