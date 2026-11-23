defmodule MedEx.Web do
  @moduledoc "Locates MedEx's packaged browser assets."

  def asset_path(name) when name in ~w(session_hook.js pcm_capture.js pcm_worklet.js) do
    app = Application.get_application(__MODULE__)
    Application.app_dir(app, "priv/static/med_web/#{name}")
  end
end
