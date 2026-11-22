defmodule MedWeb.Signaling do
  @moduledoc """
  Browser signaling message normalization and reconnect handshake contract for
  MedEx live sessions.
  """

  alias MedCore.Session

  @type client_signal ::
          {:join, String.t(), String.t(), atom(), non_neg_integer()}
          | {:leave, String.t(), String.t(), non_neg_integer()}

  @doc """
  Normalizes a browser signaling event into a pure `MedCore.Session` event.
  """
  @spec to_session_event(client_signal()) :: Session.event()
  def to_session_event({:join, peer_id, connection_id, role, t_ms}) do
    {:peer_connected, %{peer_id: peer_id, connection_id: connection_id, role: role, t_ms: t_ms}}
  end

  def to_session_event({:leave, peer_id, connection_id, t_ms}) do
    {:peer_disconnected, %{peer_id: peer_id, connection_id: connection_id, t_ms: t_ms}}
  end

  @doc """
  Returns the shipped browser hook asset relative path inside `priv/`.
  """
  @spec hook_asset_path() :: String.t()
  def hook_asset_path do
    "static/med_web/session_hook.js"
  end

  @doc """
  Resolves the absolute path to the shipped browser hook asset whether loaded
  from `:med_web` in source mode or from the Welded `:med_ex` SDK package.
  """
  @spec hook_asset_full_path() :: String.t()
  def hook_asset_full_path do
    app = Application.get_application(__MODULE__) || :med_web
    Path.join([Application.app_dir(app), "priv", hook_asset_path()])
  end
end
