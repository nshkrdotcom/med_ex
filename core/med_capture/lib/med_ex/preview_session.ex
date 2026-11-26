defmodule MedEx.PreviewSession do
  @moduledoc false

  def start_encoder do
    start_encoder(Application.get_env(:med_ex, :preview_provider))
  end

  def start_encoder(provider) do
    if is_atom(provider) and Code.ensure_loaded?(provider) and
         function_exported?(provider, :start_legacy, 1),
       do: provider.start_legacy(self()),
       else: {:error, :preview_unavailable}
  end

  # Capture traps exits; this process intentionally does not. Its link to
  # the provider's encoder is established inside start_link, before a PID is
  # returned. An exit signal can therefore cancel even an unfinished startup.
  def start_link(capture, start_encoder) do
    spawn_link(fn ->
      case start_encoder.() do
        {:ok, supervisor, pipeline} ->
          # A normal supervisor exit would otherwise be ignored by the link.
          ref = Process.monitor(supervisor)
          loop(capture, pipeline, ref)

        {:error, reason} ->
          exit(reason)
      end
    end)
  end

  defp loop(capture, pipeline, ref) do
    receive do
      {:DOWN, ^ref, :process, _supervisor, reason} ->
        exit(reason)

      {:preview_ready, ^pipeline} ->
        send(capture, {:preview_ready, self()})
        loop(capture, pipeline, ref)

      {:pcm, _index, _pcm} = frame ->
        send(pipeline, frame)
        loop(capture, pipeline, ref)

      {:preview_encoded, ^pipeline, index, payload} ->
        send(capture, {:preview_encoded, self(), index, payload})
        loop(capture, pipeline, ref)
    end
  end
end
