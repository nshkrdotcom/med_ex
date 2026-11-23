defmodule MedEx.Preview.Clock do
  @moduledoc """
  Tracks an unwrapped 48 kHz RTP media clock across captures for one preview peer.

  Start with `nil`. Within a capture the clock follows the source sample index,
  including gaps from dropped preview frames. The next capture starts one 20 ms
  packet after the last tick sent to the peer.
  """

  @enforce_keys [:capture, :index, :tick]
  defstruct @enforce_keys

  @type t :: %__MODULE__{capture: term(), index: non_neg_integer(), tick: non_neg_integer()}

  @doc "Advances the peer's clock for a delivered Opus packet."
  @spec advance(t() | nil, term(), non_neg_integer()) :: t()
  def advance(previous, capture, index) do
    tick =
      case previous do
        nil -> index
        %{capture: ^capture, index: last, tick: tick} -> tick + index - last
        %{tick: tick} -> tick + 960
      end

    %__MODULE__{capture: capture, index: index, tick: tick}
  end
end
