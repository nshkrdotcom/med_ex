defmodule MedWeb.Signaling do
  @moduledoc "Locates the browser hook in a source child or the released SDK."

  def hook_asset_full_path do
    app = Application.get_application(__MODULE__) || :med_web
    Application.app_dir(app, "priv/static/med_web/session_hook.js")
  end
end
