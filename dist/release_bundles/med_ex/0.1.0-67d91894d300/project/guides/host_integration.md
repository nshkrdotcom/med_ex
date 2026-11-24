# Host integration

Use Elixir 1.20 with an OTP version supported by ExWebRTC. On Ubuntu 26.04 the native dependencies use a C compiler, pkg-config and OpenSSL development headers.

Start a send-only peer with `MedRTC.Preview.answer/1` after receiving an audio offer with ICE candidates. The host owns authorization, signaling and peer teardown. Inject the Phoenix Socket constructor, socket path, topic function and control selectors into `createMedExHook`. Serve the ES module returned by `MedWeb.Signaling.hook_asset_full_path/0`. The channel accepts a join carrying `connection_id`, returns `session_id`, then answers an `offer` message carrying SDP with an SDP reply.

For fixture replay, provide a mono PCM16 WAV and a paired Ogg/Opus input with 20 ms frames. `MedRTC.WavCapture.record/4` keeps WAV finalization independent of preview. Fabric owns its own fixture preparation and external lab services.
