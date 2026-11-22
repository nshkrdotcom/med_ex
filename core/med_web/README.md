<p align="center">
  <img src="assets/med_web.svg" width="200" height="200" alt="MedWeb logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_ex">
    <img alt="GitHub: med_ex" src="https://img.shields.io/badge/GitHub-med_ex-0b0f14?logo=github" />
  </a>
  <a href="LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# MedWeb

`med_web` is the reusable browser-integration boundary of [MedEx](../../README.md). It translates WebRTC signaling lifecycles into `MedCore.Session` events and ships the browser-side `RTCPeerConnection` JavaScript hook inside `priv/static/med_web/session_hook.js`.

---

## What This Owns (and Does Not Own)

**`med_web` owns:**
- `MedWeb.Signaling.to_session_event/1` — Maps signaling join/leave tuples into `MedCore.Session` `:peer_connected` / `:peer_disconnected` events.
- `MedWeb.Signaling.hook_asset_path/0` and `hook_asset_full_path/0` — Resolves `priv/static/med_web/session_hook.js` using `Application.get_application(__MODULE__)`, so the exact same code locates the asset in both `:med_web` source mode and the Welded `:med_ex` SDK monolith.
- `priv/static/med_web/session_hook.js` — Reusable browser hook managing `RTCPeerConnection` SDP offer/answer negotiation, ICE candidates, and reconnect lifecycle without duplicating WebRTC plumbing in host apps.

**`med_web` does not own:**
- The Phoenix endpoint, HTTP routes, encounter authorization, or clinical exam LiveViews. Those belong to host applications such as `med_fabric/apps/exam`, which mounts the shipped `session_hook.js` inside a `phx-update="ignore"` container and serves it at `/med_ex/session_hook.js`.

---

## Walkthrough

```elixir
# Resolve the shipped browser hook (works identically in :med_web and Welded :med_ex)
path = MedWeb.Signaling.hook_asset_full_path()
true = File.regular?(path)

# Translate a Phoenix Channel join into a pure MedCore.Session event
event = MedWeb.Signaling.to_session_event({:join, "clin_1", "conn_a", :clinician, 100})
```

See `test/med_web_test.exs` and `med_fabric/apps/exam/test/mf_exam_web_test.exs` for end-to-end verification of asset serving, Phoenix Channel signaling, and LiveView `phx-update="ignore"` hook mounting.

---

## Commands & Verification

```bash
cd core/med_web
mix test
mix credo --strict
mix dialyzer --force-check
node --check priv/static/med_web/session_hook.js
```

## Planned Extensions (Deferred Until Needed)

Reusable LiveView function components (`<.signal_integrity_badge />`, `<.sync_waveform_canvas />`) and a WebAudio `AudioWorklet` ring buffer for raw 4 kHz PCM playback will be added once a live desktop browser test exercises them.

## Upstream References

- LiveExWebRTC: https://github.com/elixir-webrtc/live_ex_webrtc
- ExWebRTC Dashboard: https://github.com/elixir-webrtc/ex_webrtc_dashboard

## Related Packages

- [MedEx Workspace](../../README.md)
- [MedCore](../med_core/README.md)
- [MedRTC](../med_rtc/README.md)
- [MedAdapters](../med_adapters/README.md)
- [MedPulse](../../apps/med_pulse/README.md)
