# Host integration

Use Elixir 1.20 with an OTP version supported by ExWebRTC. On Ubuntu 26.04 the native dependencies use a C compiler, pkg-config and OpenSSL development headers.

Start a send-only peer with `MedEx.Preview.answer/1` after receiving an audio offer with ICE candidates. The host owns authorization, signaling and peer teardown. Inject the Phoenix Socket constructor, socket path, topic function and control selectors into `createMedExHook`. Serve the ES module returned by `MedEx.Web.asset_path("session_hook.js")`. The channel accepts a join carrying `connection_id`, returns `session_id`, then answers an `offer` message carrying SDP with an SDP reply.

Start one `MedEx.Capture` under the host supervision tree. Pass an acquisition
ID, producer PID as `:owner`, and artifact directory to `start_link/1`. Call `push/3` from a single source
with the first sample index and PCM bytes, then call `finish/1` to finalize the
WAV and return `MedEx.Evidence`.

A connected preview peer calls `MedEx.Capture.subscribe/1` in its owner
process. It receives `{:med_ex_preview, capture, sample_index, packet}`. Send
the packet via `MedEx.Preview.send_opus/4` using a per-peer packet sequence and
the supplied sample index. Call `MedEx.Capture.demand/1` after processing
the packet. A replacement peer can subscribe to the same capture.

## Live PCM transport

The live-input browser helper `pcm_capture.js` accepts an open, authenticated
WebSocket, the URL of `pcm_worklet.js`, and an outcome callback. Serve both
assets from the SDK. Microphone capture needs a secure browser context.

Binary messages contain an eight-byte big-endian first sample position and
up to 960 mono PCM16LE samples at 48 kHz. The host returns one text `ack`
after accepting each frame. The browser sends text `finish` after draining
its last frame. Return a terminal outcome after durable intake, then close
the connection. A disconnect before finish aborts the acquisition.

Pass `:ice_servers` to `MedEx.Preview.answer/2` and `iceServers` to the browser hook for host-managed ICE configuration. The verified lab uses direct local candidates.

The browser PCM helper calls its recording callback after the host acknowledges
the first full frame. Allow up to one second for a continuous microphone start.
A source gap after the first frame ends the capture with `capture_gap`.
