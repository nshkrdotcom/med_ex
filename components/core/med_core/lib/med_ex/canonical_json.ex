defmodule MedEx.CanonicalJSON do
  @moduledoc "MEJ1 metadata bytes. Numbers must already be decimal strings."
  @type value :: binary() | boolean() | nil | [value()] | %{binary() => value()}

  @spec encode(value()) :: binary()
  def encode(value), do: value |> emit() |> IO.iodata_to_binary()

  @doc "Accept only exact canonical bytes. Re-encoding also rejects duplicate keys."
  def decode(bytes) when is_binary(bytes) do
    with {:ok, value} <- JSON.decode(bytes),
         true <- encode(value) == bytes do
      {:ok, value}
    else
      _ -> {:error, :invalid_mej1}
    end
  rescue
    ArgumentError -> {:error, :invalid_mej1}
  end

  defp emit(nil), do: "null"
  defp emit(true), do: "true"
  defp emit(false), do: "false"

  defp emit(value) when is_binary(value) do
    unless String.valid?(value), do: raise(ArgumentError, "invalid UTF-8")
    [34, for(<<cp::utf8 <- value>>, do: escape(cp)), 34]
  end

  defp emit(value) when is_list(value), do: [91, join(Enum.map(value, &emit/1)), 93]

  defp emit(value) when is_map(value) and not is_struct(value) do
    fields =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, item} ->
        unless is_binary(key) and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, key),
          do: raise(ArgumentError, "MEJ1 object keys must be ASCII identifiers")

        [emit(key), 58, emit(item)]
      end)

    [123, join(fields), 125]
  end

  defp emit(_),
    do: raise(ArgumentError, "MEJ1 accepts strings, booleans, null, arrays and objects")

  defp join(values), do: Enum.intersperse(values, 44)
  defp escape(34), do: "\\\""
  defp escape(92), do: "\\\\"
  defp escape(8), do: "\\b"
  defp escape(12), do: "\\f"
  defp escape(10), do: "\\n"
  defp escape(13), do: "\\r"
  defp escape(9), do: "\\t"

  defp escape(cp) when cp < 32,
    do: "\\u" <> String.pad_leading(Integer.to_string(cp, 16) |> String.downcase(), 4, "0")

  defp escape(cp), do: <<cp::utf8>>
end
