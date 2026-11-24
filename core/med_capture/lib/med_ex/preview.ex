defmodule MedEx.Preview do
  @moduledoc "Legacy preview handle. The peer PID belongs to the configured RTC provider."
  @enforce_keys [:pid, :track_id]
  defstruct @enforce_keys
  @type t :: %__MODULE__{pid: pid(), track_id: term()}

  def answer(sdp, opts \\ []) when is_binary(sdp) do
    with {:ok, provider} <- provider(), do: provider.answer(sdp, opts)
  end

  def send_opus(%__MODULE__{} = peer, payload, sequence, sample) do
    with {:ok, provider} <- provider(), do: provider.send_opus(peer, payload, sequence, sample)
  end

  def close(%__MODULE__{} = peer) do
    with {:ok, provider} <- provider(), do: provider.close(peer)
  end

  defp provider do
    case :persistent_term.get({__MODULE__, :provider}, nil) do
      nil -> :global.trans({{__MODULE__, :configure}, self()}, &freeze_provider/0, [node()])
      module -> {:ok, module}
    end
  end

  defp freeze_provider do
    module =
      :persistent_term.get({__MODULE__, :provider}, Application.get_env(:med_ex, :rtc_provider))

    if is_atom(module) and Code.ensure_loaded?(module) and
         Enum.all?([answer: 2, send_opus: 4, close: 1], fn {name, arity} ->
           function_exported?(module, name, arity)
         end) do
      :persistent_term.put({__MODULE__, :provider}, module)
      {:ok, module}
    else
      {:error, :rtc_unavailable}
    end
  end
end
