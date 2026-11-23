# Host integration

This guide covers everything a Phoenix or Elixir host needs to capture indexed
mono PCM16LE audio with `MedEx.Capture`, stream an independent live Opus preview
over `MedEx.Preview`, and serve MedEx's packaged browser helpers.

## Prerequisites

- Elixir `~> 1.20` (tested on Elixir `1.20.5` / OTP `29.1.2`).
- Ubuntu 26.04 native build packages for WebRTC (`ex_dtls`, `ex_libsrtp`):
  `build-essential`, `pkg-config`, and `libssl-dev`.
- Live Opus encoding uses `membrane_opus_plugin`, which uses precompiled
  `libopus` binaries on supported Linux/macOS targets (install `libopus-dev` if
  compiling `libopus` from source).
- Browser microphone capture (`getUserMedia` + `AudioWorklet`) requires a secure
  context (`https://`, or `http://localhost` / `http://127.0.0.1` for local dev).

## 1. Serve the packaged browser assets

`MedEx.Web.asset_path/1` resolves the three JavaScript files shipped inside
`:med_ex`:

- `"session_hook.js"` — LiveView hook helper (`createMedExHook/1`) for the
  clinician's receive-only WebRTC preview.
- `"pcm_capture.js"` — patient-browser capture helper (`startPCM/4`).
- `"pcm_worklet.js"` — `AudioWorkletProcessor` (`"med-ex-indexed-pcm"`) loaded
  by `startPCM/4`.

Serve all three as `application/javascript` from your endpoint:

```elixir
defp serve_med_ex_assets(%Plug.Conn{path_info: ["med_ex", name]} = conn, _opts)
     when name in ~w(session_hook.js pcm_capture.js pcm_worklet.js) do
  conn
  |> Plug.Conn.put_resp_content_type("application/javascript")
  |> Plug.Conn.send_file(200, MedEx.Web.asset_path(name))
  |> Plug.Conn.halt()
end

defp serve_med_ex_assets(conn, _opts), do: conn
```

## 2. Supervise live capture in your host

Start a host-owned `DynamicSupervisor` (and optionally a `Registry` if preview
channels need to look up active captures by encounter). MedEx starts no global
capture processes.

```elixir
# In your application supervision tree:
children = [
  {Registry, keys: :unique, name: MyApp.ActiveCapture},
  {DynamicSupervisor, strategy: :one_for_one, name: MyApp.Captures}
]
```

Each capture process takes `:owner`, `:acquisition_id`, and `:artifact_dir`:

```elixir
{:ok, capture} =
  DynamicSupervisor.start_child(
    MyApp.Captures,
    {MedEx.Capture,
     owner: self(),
     acquisition_id: acquisition_id,
     artifact_dir: artifact_dir}
  )
```

`MedEx.Capture` monitors `:owner` and aborts (deleting its temporary `.part`
file) if `:owner` exits before `finish/1`.

### Handling binary PCM WebSocket frames

In your authenticated WebSocket handler (e.g. a `WebSock` module), decode each
binary frame as an 8-byte unsigned big-endian starting sample index followed by
PCM16LE bytes, push to `MedEx.Capture.push/3`, and reply with text `"ack"`:

```elixir
def handle_in({<<index::unsigned-big-64, pcm::binary>>, [opcode: :binary]}, state) do
  case MedEx.Capture.push(state.capture, index, pcm) do
    :ok -> {:push, {:text, "ack"}, state}
    {:error, _reason} -> {:stop, :normal, 1008, {:text, "invalid_capture"}, state}
  end
end

def handle_in({"finish", [opcode: :text]}, state) do
  case MedEx.Capture.finish(state.capture) do
    {:ok, %MedEx.Evidence{} = evidence} ->
      # Persist finalized evidence before closing the socket.
      :ok = MyApp.ClinicalStore.record_ready(state.encounter_id, evidence)
      {:stop, :normal, 1000, {:text, "ready"}, state}

    {:error, _reason} ->
      {:stop, :normal, 1011, {:text, "capture_failed"}, state}
  end
end
```

### Capture rules and error returns

| Rule / Operation | Behavior |
| --- | --- |
| Sample format | Mono 48 kHz signed 16-bit little-endian PCM (`PCM16LE`). |
| Frame size | Even byte count in `2..1920` (up to 960 samples / 20 ms). Only one short tail frame (`< 1920` bytes) is allowed, immediately before `finish/1`. |
| Contiguity & limit | `first_sample` must start at `0` and advance contiguously without gaps, up to 30 minutes (`86_400_000` samples). Violations return `{:error, :invalid_frame}` and stop the capture. |
| `finish/1` | Returns `{:ok, %MedEx.Evidence{}}`, `{:error, :empty_capture}` (0 samples pushed), `{:error, :artifact_conflict}` (existing file digest mismatch), or `{:error, posix}`. |
| Preview fan-out | Only full 1,920-byte frames are offered to the preview encoder. Preview lag, drop, or encoder exit never blocks or aborts WAV capture. |

### `MedEx.Evidence` fields

`MedEx.Capture.finish/1` returns `%MedEx.Evidence{}`:

| Field | Value |
| --- | --- |
| `:acquisition_id` | Host-provided acquisition ID string |
| `:artifact_key` | Content-addressed filename (`"<file_sha256>.wav"`) |
| `:file_sha256` | Lowercase hex SHA-256 of the complete WAV file |
| `:pcm_sha256` | Lowercase hex SHA-256 of the raw PCM16LE bytes |
| `:kind` | `:audio_pcm16_wav` |
| `:sample_rate_hz` | `48_000` |
| `:first_sample` | `0` (inclusive) |
| `:end_sample` | Exclusive ending sample index |
| `:sample_count` | Total captured mono samples |
| `:continuity` | `:observed_continuous` |

## 3. Wire the preview signaling channel

The clinician's Phoenix Channel owns one replaceable `MedEx.Preview` peer.
`MedEx.Preview.answer/2` sends `{:ex_webrtc, peer.pid, {:connection_state_change, state}}`
messages to the channel process. Once `:connected`, subscribe the channel to
the active `MedEx.Capture` (only one subscriber is active at a time; a newer
subscriber replaces the previous one).

```elixir
defmodule MyAppWeb.PreviewChannel do
  use Phoenix.Channel

  alias MedEx.{Capture, Preview}

  @impl true
  def join("signaling:" <> encounter_id, %{"connection_id" => id}, socket)
      when is_binary(id) do
    # Authorize socket.assigns here before allowing join.
    {:ok, %{session_id: encounter_id},
     assign(socket,
       encounter_id: encounter_id,
       peer: nil,
       capture: nil,
       sequence: 0,
       clock: nil,
       connected: false
     )}
  end

  @impl true
  def handle_in("offer", %{"sdp" => sdp}, %{assigns: %{peer: nil}} = socket) do
    opts = [ice_servers: Application.get_env(:my_app, :ice_servers, [])]

    case Preview.answer(sdp, opts) do
      {:ok, peer, answer_sdp} ->
        {:reply, {:ok, %{sdp: answer_sdp}}, assign(socket, :peer, peer)}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "negotiation_failed"}}, socket}
    end
  end

  @impl true
  def handle_info(
        {:ex_webrtc, pid, {:connection_state_change, :connected}},
        %{assigns: %{peer: %{pid: pid}, connected: false}} = socket
      ) do
    # Subscribe to future capture starts and attach if one is already running.
    send(self(), :attach_active_capture)
    {:noreply, assign(socket, :connected, true)}
  end

  def handle_info({:capture_started, capture}, %{assigns: %{connected: true}} = socket) do
    case Capture.subscribe(capture) do
      :ok ->
        {:noreply, assign(socket, :capture, capture)}

      {:error, :preview_unavailable} ->
        push(socket, "preview_failed", %{})
        {:noreply, socket}
    end
  end

  def handle_info(
        {:med_ex_preview, capture, sample_index, packet},
        %{assigns: %{capture: capture, peer: peer, sequence: seq, clock: clock}} = socket
      ) do
    tick = next_tick(clock, capture, sample_index)
    :ok = Preview.send_opus(peer, packet, seq, tick)
    :ok = Capture.demand(capture)
    {:noreply, assign(socket, sequence: seq + 1, clock: {capture, sample_index, tick})}
  end

  def handle_info({:med_ex_preview_failed, capture, _reason}, %{assigns: %{capture: capture}} = socket) do
    push(socket, "preview_failed", %{})
    {:noreply, assign(socket, :capture, nil)}
  end

  def handle_info(
        {:ex_webrtc, pid, {:connection_state_change, state}},
        %{assigns: %{peer: %{pid: pid}}} = socket
      )
      when state in [:failed, :closed],
      do: {:stop, :normal, socket}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if peer = socket.assigns[:peer], do: Preview.close(peer)
    :ok
  end

  # Keep RTP media timestamps monotonic if a new capture starts on the same peer.
  defp next_tick(nil, _capture, index), do: index
  defp next_tick({capture, last, tick}, capture, index), do: tick + index - last
  defp next_tick({_prev, _last, tick}, _capture, _index), do: tick + 960
end
```

Pass `:ice_servers` to `MedEx.Preview.answer/2` and `iceServers` to
`createMedExHook/1` for host-managed STUN/TURN configuration. The default `[]`
uses direct local candidates.

## 4. Browser preview hook (`session_hook.js`)

Wrap the clinician preview controls in a LiveView container with
**`phx-update="ignore"`** (required so LiveView DOM diffs do not tear down the
active `<audio>` stream), `data-token` (sent in Phoenix Socket params), an
`<audio>` element, and an optional `[role="status"]` element:

```heex
<section
  id="diagnostic-preview"
  phx-hook="MedExSessionHook"
  phx-update="ignore"
  data-token={@socket_token}
  data-encounter-id={@encounter_id}
>
  <button id="preview-play" type="button">Play preview</button>
  <button id="preview-disconnect" type="button">Disconnect</button>
  <button id="preview-reconnect" type="button">Reconnect</button>
  <audio autoplay playsinline></audio>
  <p role="status">idle</p>
</section>
```

Register the hook on your `LiveSocket`:

```js
import { Socket } from "/assets/phoenix.mjs";
import { LiveSocket } from "/assets/phoenix_live_view.esm.js";
import { createMedExHook } from "/med_ex/session_hook.js";

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: {
    MedExSessionHook: createMedExHook({
      Socket,
      socketPath: "/socket",
      topic: el => "signaling:" + el.dataset.encounterId,
      play: "#preview-play",
      disconnect: "#preview-disconnect",
      reconnect: "#preview-reconnect",
      iceServers: []
    })
  }
});
```

Channel protocol expected by `createMedExHook`:

1. Joins `topic(el)` with `{ connection_id: crypto.randomUUID() }`, expecting
   `{ session_id }`.
2. Gathers browser ICE candidates and pushes `"offer"` with `{ sdp }`, expecting
   `{ sdp }` answer.
3. Handles server-pushed `"preview_failed"` by closing the peer cleanly and
   displaying a retry status without affecting capture.

## 5. Browser live PCM capture (`pcm_capture.js` & `pcm_worklet.js`)

`pcm_capture.js` exports:

```js
import { startPCM } from "/med_ex/pcm_capture.js";

const socket = new WebSocket("wss://example.test/pcm");
await new Promise((resolve, reject) => {
  socket.onopen = resolve;
  socket.onerror = reject;
  socket.onclose = reject;
});

const handle = await startPCM(
  socket,
  "/med_ex/pcm_worklet.js",
  outcome => console.log("Capture ended:", outcome),
  () => console.log("Recording active (first frame acknowledged)")
);

// Later, to finalize cleanly (drains remaining samples and sends text "finish"):
handle.finish();

// Or to abort immediately:
handle.abort();
```

### Live PCM wire protocol and outcome codes

- **Audio constraints:** `AudioContext({ sampleRate: 48000 })` (fails with
  `"setup_failed"` if the browser context cannot run at 48 kHz) and
  `getUserMedia` with `channelCount: { exact: 1 }` and `echoCancellation`,
  `noiseSuppression`, and `autoGainControl` set to `{ exact: false }`.
- **Binary frames:** 8-byte unsigned big-endian `first_sample` index followed by
  up to 960 mono `PCM16LE` samples (1,920 bytes).
- **Flow control:** The worklet starts with 8 in-flight frame credits. The host
  must reply with text `"ack"` after accepting each frame. After the first
  `"ack"`, `startPCM/4` invokes `onRecording()`.
- **Normal finish:** `handle.finish()` drains any final partial frame, sends
  text `"finish"`, and waits for the host's terminal text frame (for example
  `"ready"` or `"capture_failed"`).
- **Startup & gap rules:** Allow up to 1 second for continuous microphone
  startup (`"capture_source_timeout"` if no samples arrive). Any source gap
  after the first frame ends capture with `"capture_gap"`.

Terminal strings delivered to `onOutcome(outcome)`:

| Outcome | Meaning |
| --- | --- |
| Host text frame (e.g. `"ready"`, `"capture_failed"`, `"invalid_capture"`) | Any non-`"ack"` text message sent by the host closes capture with that string. |
| `"setup_failed"` | Microphone permission/constraints, 48 kHz context, worklet load, or socket pre-check failed (`startPCM/4` also rejects). |
| `"capture_source_timeout"` | No audio samples arrived within 1 second of start or during an empty-input stall. |
| `"capture_gap"` | AudioWorklet detected a discontinuity in `currentFrame` after capture became active. |
| `"capture_overflow"` | All 8 in-flight frame credits were exhausted without host `"ack"` replies. |
| `"source_ended"` | Browser media track ended unexpectedly. |
| `"disconnected"` | WebSocket closed or errored before a terminal host outcome arrived. |
| `"aborted"` | Host browser code called `handle.abort()`. |
