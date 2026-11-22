defmodule MedRTC.SessionServer do
  @moduledoc """
  OTP `GenServer` owning a live `%MedCore.Session{}` and dispatching emitted
  producer facts to registered subscribers.
  """

  use GenServer

  alias MedCore.Session

  @type start_opt ::
          {:session, Session.t()}
          | {:subscribers, [pid()]}
          | {:name, GenServer.name()}

  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {gen_opts, state_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, state_opts, gen_opts)
  end

  @spec dispatch(GenServer.server(), Session.event()) :: {Session.t(), [Session.effect()]}
  def dispatch(server, event) do
    GenServer.call(server, {:dispatch, event})
  end

  @spec snapshot(GenServer.server()) :: Session.t()
  def snapshot(server) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    subscribers = Keyword.get(opts, :subscribers, [])
    {:ok, %{session: session, subscribers: subscribers}}
  end

  @impl true
  def handle_call({:dispatch, event}, _from, state) do
    {next_session, effects} = Session.step(state.session, event)

    for effect <- effects, pid <- state.subscribers do
      send(pid, {:med_rtc_effect, next_session.id, effect})
    end

    {:reply, {next_session, effects}, %{state | session: next_session}}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state.session, state}
  end
end
