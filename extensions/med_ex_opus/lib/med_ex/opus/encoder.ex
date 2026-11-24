defmodule MedEx.Opus.Encoder.Source do
  @moduledoc false
  use Membrane.Source

  def_output_pad(:output, accepted_format: Membrane.RawAudio, flow_control: :push)

  @impl true
  def handle_playing(_ctx, state) do
    {[
       stream_format:
         {:output, %Membrane.RawAudio{sample_rate: 48_000, channels: 1, sample_format: :s16le}}
     ], state}
  end

  @impl true
  def handle_parent_notification({index, pcm}, _ctx, state) do
    {[buffer: {:output, %Membrane.Buffer{payload: pcm, pts: div(index * 1_000_000_000, 48_000)}}],
     state}
  end
end

defmodule MedEx.Opus.Encoder.Sink do
  @moduledoc false
  use Membrane.Sink

  def_input_pad(:input, accepted_format: Membrane.Opus, flow_control: :auto)

  @impl true
  def handle_buffer(:input, buffer, _ctx, state), do: {[notify_parent: buffer.payload], state}
end

defmodule MedEx.Opus.Encoder do
  @moduledoc false
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, owner) do
    spec =
      child(:source, MedEx.Opus.Encoder.Source)
      |> child(:encoder, %Membrane.Opus.Encoder{application: :audio})
      |> child(:sink, MedEx.Opus.Encoder.Sink)

    {[spec: spec], {owner, nil}}
  end

  @impl true
  def handle_playing(_ctx, {owner, _} = state) do
    send(owner, {:preview_ready, self()})
    {[], state}
  end

  @impl true
  def handle_info({:pcm, index, pcm}, _ctx, {owner, nil}) do
    {[notify_child: {:source, {index, pcm}}], {owner, index}}
  end

  @impl true
  def handle_child_notification(payload, :sink, _ctx, {owner, index}) do
    send(owner, {:preview_encoded, self(), index, payload})
    {[], {owner, nil}}
  end
end
