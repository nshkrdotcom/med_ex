# `MedEx.Web`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/med_ex-v0.2.0/lib/med_ex/web.ex#L1)

Locates MedEx's packaged browser JavaScript assets.

Host web applications serve these files as `application/javascript` under
their own routes:

  * `"session_hook.js"` — LiveView hook helper (`createMedExHook/1`) for the
    clinician's receive-only WebRTC preview peer.
  * `"pcm_capture.js"` — patient-browser capture helper (`startPCM` with optional input and settings callback) for
    48 kHz mono PCM16LE microphone capture over an authenticated WebSocket.
  * `"pcm_worklet.js"` — `AudioWorkletProcessor` (`"med-ex-indexed-pcm"`)
    loaded by `startPCM`.

# `asset_path`

```elixir
@spec asset_path(String.t()) :: String.t()
```

Returns the absolute filesystem path to a packaged browser asset.

Accepts `"session_hook.js"`, `"pcm_capture.js"`, or `"pcm_worklet.js"`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
