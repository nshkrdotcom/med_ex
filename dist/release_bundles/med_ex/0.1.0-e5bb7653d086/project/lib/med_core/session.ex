defmodule MedCore.Session do
  @moduledoc """
  Immutable live clinical transport session aggregate and pure reducer (`step/2`).

  A `Session` owns live participants, WebRTC connection attempts (`connection_id`),
  transient preview interruptions, independent recording continuity, and device
  acquisitions (`acquisition_id`). It can outlast individual browser reconnects
  and supports standalone capture with `encounter_ref: nil` and no connected peer.
  """

  alias MedCore.StreamSpec

  @type topology :: :server_terminated | :sfu | :hybrid
  @type session_id :: String.t()
  @type encounter_ref :: String.t() | nil
  @type connection_id :: String.t()
  @type acquisition_id :: String.t()

  @type integrity_subject ::
          {:preview_stream, String.t()}
          | {:recording_artifact, acquisition_id()}

  @type continuity_state :: :observed_continuous | :observed_gap | :unknown

  @type integrity_report :: %{
          required(:subject) => integrity_subject(),
          required(:interval_ms) => {non_neg_integer(), non_neg_integer()},
          required(:continuity) => continuity_state(),
          optional(:reasons) => [atom()]
        }

  @type event ::
          {:peer_connected,
           %{
             required(:peer_id) => String.t(),
             required(:connection_id) => connection_id(),
             required(:role) => atom(),
             required(:t_ms) => non_neg_integer(),
             optional(:stream_id) => String.t()
           }}
          | {:peer_disconnected,
             %{
               required(:peer_id) => String.t(),
               required(:connection_id) => connection_id(),
               required(:t_ms) => non_neg_integer(),
               optional(:stream_id) => String.t()
             }}
          | {:acquisition_started,
             %{
               required(:acquisition_id) => acquisition_id(),
               required(:stream_id) => String.t(),
               required(:t_ms) => non_neg_integer()
             }}
          | {:capture_completed,
             %{
               required(:acquisition_id) => acquisition_id(),
               required(:artifact_sha256) => String.t(),
               required(:interval_ms) => {non_neg_integer(), non_neg_integer()},
               required(:continuity) => continuity_state(),
               required(:delivery_id) => String.t(),
               required(:t_ms) => non_neg_integer()
             }}

  @type effect :: {:emit_fact, atom(), map()}

  @type t :: %__MODULE__{
          id: session_id(),
          encounter_ref: encounter_ref(),
          topology: topology(),
          streams: %{String.t() => StreamSpec.t()},
          participants: %{String.t() => map()},
          connections: %{connection_id() => map()},
          acquisitions: %{acquisition_id() => map()},
          preview_interruptions: [map()],
          integrity_reports: %{integrity_subject() => integrity_report()}
        }

  @enforce_keys [:id, :topology, :streams]
  defstruct [
    :id,
    :topology,
    :streams,
    encounter_ref: nil,
    participants: %{},
    connections: %{},
    acquisitions: %{},
    preview_interruptions: [],
    integrity_reports: %{}
  ]

  @doc """
  Constructs a new live clinical session. `encounter_ref` is optional (`nil` for standalone capture).
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    streams =
      opts
      |> Keyword.get(:streams, [])
      |> normalize_streams()

    %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      encounter_ref: Keyword.get(opts, :encounter_ref),
      topology: Keyword.get(opts, :topology, :server_terminated),
      streams: streams
    }
  end

  @doc """
  Pure state transition function `{next_session, effects} = step(session, event)`.
  """
  @spec step(t(), event()) :: {t(), [effect()]}
  def step(%__MODULE__{} = session, {:peer_connected, payload}) do
    %{peer_id: peer_id, connection_id: conn_id, role: role, t_ms: t_ms} = payload

    participants =
      Map.put(session.participants, peer_id, %{
        role: role,
        active_connection_id: conn_id,
        connected_at_ms: t_ms
      })

    connections =
      Map.put(session.connections, conn_id, %{
        peer_id: peer_id,
        role: role,
        state: :connected,
        connected_at_ms: t_ms
      })

    preview_interruptions =
      close_open_interruption(session.preview_interruptions, peer_id, t_ms)

    next = %{
      session
      | participants: participants,
        connections: connections,
        preview_interruptions: preview_interruptions
    }

    effects = [
      {:emit_fact, :peer_connection_changed,
       %{
         encounter_ref: session.encounter_ref,
         session_id: session.id,
         peer_id: peer_id,
         connection_id: conn_id,
         state: :connected,
         t_ms: t_ms
       }}
    ]

    {next, effects}
  end

  def step(%__MODULE__{} = session, {:peer_disconnected, payload}) do
    %{peer_id: peer_id, connection_id: conn_id, t_ms: t_ms} = payload
    stream_id = Map.get(payload, :stream_id, default_preview_stream_id(session))

    case session.connections do
      %{^conn_id => %{peer_id: ^peer_id, state: :connected} = connection} ->
        connection = Map.merge(connection, %{state: :disconnected, disconnected_at_ms: t_ms})
        next = %{session | connections: Map.put(session.connections, conn_id, connection)}

        if get_in(session.participants, [peer_id, :active_connection_id]) == conn_id do
          disconnect_preview(next, peer_id, conn_id, stream_id, t_ms)
        else
          {next, []}
        end

      _ ->
        {session, []}
    end
  end

  def step(%__MODULE__{} = session, {:acquisition_started, %{acquisition_id: id} = payload}) do
    if Map.has_key?(session.acquisitions, id),
      do: {session, []},
      else: start_acquisition(session, payload)
  end

  def step(%__MODULE__{} = session, {:capture_completed, payload}) do
    %{
      acquisition_id: acq_id,
      artifact_sha256: sha256,
      interval_ms: interval_ms,
      continuity: continuity,
      delivery_id: delivery_id,
      t_ms: t_ms
    } = payload

    case Map.get(session.acquisitions, acq_id) do
      %{state: :completed, artifact_sha256: ^sha256} ->
        {session, []}

      %{state: :completed, artifact_sha256: existing_sha} = existing ->
        updated = Map.merge(existing, %{state: :conflict, conflicting_sha256: sha256})

        next = %{
          session
          | acquisitions: Map.put(session.acquisitions, acq_id, updated)
        }

        effects = [
          {:emit_fact, :capture_conflict,
           %{
             encounter_ref: session.encounter_ref,
             session_id: session.id,
             acquisition_id: acq_id,
             existing_sha256: existing_sha,
             incoming_sha256: sha256,
             delivery_id: delivery_id,
             t_ms: t_ms
           }}
        ]

        {next, effects}

      %{state: :conflict} ->
        {session, []}

      existing ->
        subject = {:recording_artifact, acq_id}

        report = %{
          subject: subject,
          interval_ms: interval_ms,
          continuity: continuity,
          reasons: continuity_reasons(continuity)
        }

        completed =
          (existing || %{id: acq_id, stream_id: nil, started_at_ms: elem(interval_ms, 0)})
          |> Map.merge(%{
            state: :completed,
            artifact_sha256: sha256,
            interval_ms: interval_ms,
            continuity: continuity,
            completed_at_ms: t_ms
          })

        next = %{
          session
          | acquisitions: Map.put(session.acquisitions, acq_id, completed),
            integrity_reports: Map.put(session.integrity_reports, subject, report)
        }

        effects = [
          {:emit_fact, :integrity_reported,
           Map.merge(report, %{
             encounter_ref: session.encounter_ref,
             session_id: session.id,
             acquisition_id: acq_id
           })},
          {:emit_fact, :capture_completed,
           %{
             encounter_ref: session.encounter_ref,
             session_id: session.id,
             acquisition_id: acq_id,
             artifact_sha256: sha256,
             interval_ms: interval_ms,
             continuity: continuity,
             delivery_id: delivery_id,
             t_ms: t_ms
           }}
        ]

        {next, effects}
    end
  end

  defp start_acquisition(session, %{acquisition_id: acq_id, stream_id: stream_id, t_ms: t_ms}) do
    acquisitions =
      Map.put(session.acquisitions, acq_id, %{
        id: acq_id,
        stream_id: stream_id,
        state: :active,
        started_at_ms: t_ms,
        artifact_sha256: nil,
        continuity: nil
      })

    {%{session | acquisitions: acquisitions}, []}
  end

  defp disconnect_preview(session, peer_id, conn_id, stream_id, t_ms) do
    interruption = %{
      peer_id: peer_id,
      connection_id: conn_id,
      stream_id: stream_id,
      started_at_ms: t_ms,
      ended_at_ms: nil
    }

    {integrity_reports, integrity_effects} =
      if is_binary(stream_id) do
        subject = {:preview_stream, stream_id}

        report = %{
          subject: subject,
          interval_ms: {t_ms, t_ms},
          continuity: :unknown,
          reasons: [:preview_disconnected]
        }

        {
          Map.put(session.integrity_reports, subject, report),
          [{:emit_fact, :integrity_reported, Map.put(report, :session_id, session.id)}]
        }
      else
        {session.integrity_reports, []}
      end

    next = %{
      session
      | participants:
          Map.update!(session.participants, peer_id, &%{&1 | active_connection_id: nil}),
        preview_interruptions: session.preview_interruptions ++ [interruption],
        integrity_reports: integrity_reports
    }

    effects =
      [
        {:emit_fact, :peer_connection_changed,
         %{
           encounter_ref: session.encounter_ref,
           session_id: session.id,
           peer_id: peer_id,
           connection_id: conn_id,
           state: :disconnected,
           t_ms: t_ms
         }}
      ] ++ integrity_effects

    {next, effects}
  end

  defp normalize_streams(streams) when is_map(streams), do: streams

  defp normalize_streams(streams) when is_list(streams) do
    Map.new(streams, fn %StreamSpec{id: id} = spec -> {id, spec} end)
  end

  defp default_preview_stream_id(%__MODULE__{streams: streams}) do
    case Map.keys(streams) do
      [only] -> only
      _ -> nil
    end
  end

  defp close_open_interruption(interruptions, peer_id, t_ms) do
    Enum.map(interruptions, fn entry ->
      if entry.peer_id == peer_id and is_nil(entry.ended_at_ms) do
        %{entry | ended_at_ms: t_ms}
      else
        entry
      end
    end)
  end

  defp continuity_reasons(:observed_continuous), do: []
  defp continuity_reasons(:observed_gap), do: [:observed_gap]
  defp continuity_reasons(:unknown), do: [:continuity_unknown]
end
