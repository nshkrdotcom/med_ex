defmodule MedEx.ContractRules do
  @moduledoc false
  def uint?(v, max), do: is_integer(v) and v >= 0 and v <= max
  def id?(v), do: is_binary(v) and byte_size(v) in 1..256 and String.valid?(v)
  def key?(v), do: id?(v) and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, v)
  def signed?(v), do: is_integer(v) and abs(v) <= 0xFFFFFFFFFFFFFFFF

  def digest?(v),
    do: is_binary(v) and byte_size(v) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, v)

  def config?(v), do: v == :unknown or uint?(v, 0xFFFFFFFE)

  def rational?({n, d}),
    do: uint?(n, 0xFFFFFFFFFFFFFFFF) and n > 0 and uint?(d, 0xFFFFFFFFFFFFFFFF) and d > 0

  def rational?(_), do: false
  def list?([], _max, _predicate), do: true

  def list?([head | tail], max, predicate) when max > 0,
    do: predicate.(head) and list?(tail, max - 1, predicate)

  def list?(_, _, _), do: false

  def fact?(%{name: n, origin: o, value: v} = f) when map_size(f) == 3,
    do: id?(n) and o in [:claimed, :observed] and scalar?(v)

  def fact?(_), do: false

  def scalar?(v),
    do: v in [:unknown, true, false] or id?(v) or (is_integer(v) and abs(v) <= 0xFFFFFFFFFFFFFFFF)
end
