defmodule MedEx.Web do
  @moduledoc """
  Locates MedEx's packaged browser JavaScript assets.

  Host web applications serve these files as `application/javascript` under
  their own routes:

    * `"session_hook.js"` — LiveView hook helper (`createMedExHook/1`) for the
      clinician's receive-only WebRTC preview peer.
    * `"pcm_capture.js"` — patient-browser capture helper (`startPCM` with optional input and settings callback) for
      48 kHz mono PCM16LE microphone capture over an authenticated WebSocket.
    * `"pcm_worklet.js"` — `AudioWorkletProcessor` (`"med-ex-indexed-pcm"`)
      loaded by `startPCM`.
  """

  @doc """
  Returns the absolute filesystem path to a packaged browser asset.

  Accepts `"session_hook.js"`, `"pcm_capture.js"`, or `"pcm_worklet.js"`.
  """
  @spec asset_path(String.t()) :: String.t()
  def asset_path(name) when name in ~w(session_hook.js pcm_capture.js pcm_worklet.js) do
    app = Application.get_application(__MODULE__)
    Application.app_dir(app, "priv/static/med_web/#{name}")
  end
end
