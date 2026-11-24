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
- `"pcm_capture.js"` — patient-browser capture helper (`startPCM`).
- `"pcm_worklet.js"` — `AudioWorkletProcessor` (`"med-ex-indexed-pcm"`) loaded
  by `startPCM`.

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

For the preview example below, start `{Phoenix.PubSub, name: MyApp.PubSub}`
in the host supervisor as well. Register the encounter in `MyApp.ActiveCapture`
from the producer process and broadcast after the capture starts.

Before capture, reserve an acquisition ID with its producer and encounter in the
host store. Create the attempt's artifact directory and give the browser the ID.
This lets the host correlate a finalized WAV with its reservation even if the
socket exits during finish. Use the ID for subsequent outcome lookup.

Each capture process takes `:owner`, `:acquisition_id`, and `:artifact_dir`.

```elixir
{:ok, _} = Registry.register(MyApp.ActiveCapture, encounter_id, nil)

{:ok, capture} =
  DynamicSupervisor.start_child(
    MyApp.Captures,
    {MedEx.Capture,
     owner: self(),
     acquisition_id: acquisition_id,
     artifact_dir: artifact_dir}
  )

Registry.update_value(MyApp.ActiveCapture, encounter_id, fn _ -> capture end)
Phoenix.PubSub.broadcast(MyApp.PubSub, "preview:" <> encounter_id, {:capture_started, capture})
```

`MedEx.Capture` monitors `:owner` and aborts (deleting its temporary `.part`
file) if `:owner` exits before `finish/1`. The same PID must call `push/3`
and `finish/1`. A different caller receives `{:error, :not_owner}` and the
active recording continues.

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
      :ok = MyApp.ClinicalStore.mark_ready(state.acquisition_id, evidence)
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
| Preview fan-out | Only full 1,920-byte frames are offered under one-frame demand. A disposable preview session starts and owns the encoder outside Capture's callbacks. A slow or failed preview drops preview frames while the writer continues. |

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
    opts = MyApp.Media.preview_ice_options(socket.assigns.encounter_id)

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
    encounter_id = socket.assigns.encounter_id
    :ok = Phoenix.PubSub.subscribe(MyApp.PubSub, "preview:" <> encounter_id)

    case Registry.lookup(MyApp.ActiveCapture, encounter_id) do
      [{_producer, capture}] when is_pid(capture) -> send(self(), {:capture_started, capture})
      _ -> :ok
    end
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
  catch
    :exit, _ -> {:noreply, socket}
  end

  def handle_info(
        {:med_ex_preview, capture, sample_index, packet},
        %{assigns: %{capture: capture, peer: peer, sequence: seq, clock: clock}} = socket
      ) do
    clock = Preview.Clock.advance(clock, capture, sample_index)
    :ok = Preview.send_opus(peer, packet, seq, clock.tick)
    :ok = Capture.demand(capture)
    {:noreply, assign(socket, sequence: seq + 1, clock: clock)}
  end

  def handle_info({:med_ex_preview_replaced, capture}, %{assigns: %{capture: capture}} = socket) do
    push(socket, "preview_replaced", %{})
    {:noreply, assign(socket, capture: nil, connected: false)}
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

end
```

`MedEx.Preview.Clock.advance/3` preserves the media clock across captures on
the same peer and across dropped preview frames. `send_opus/4` owns RTP sequence
and timestamp wrapping. The host retains only the sequence and clock state.

The subscription waits for its private encoder session to start, but Capture
can process writer calls during that wait. The session is scoped to the current
subscriber and capture; replacement, subscriber loss, and capture teardown
cancel it. A host does not need another named supervisor or a MedEx application
supervision tree.

For the example, implement `MyApp.Media.preview_ice_options/1` to return
`[ice_servers: servers, ice_transport_policy: :all]` or use `:relay` with TURN
credentials scoped to the preview peer. Give the conversation peers and browser
preview the corresponding WebRTC `iceServers` and `iceTransportPolicy`
configuration with credentials scoped to their sessions. Defaults are an empty
server list and `:all`. A relay deployment can inspect each selected candidate
pair with browser `getStats()`. Measure PCM acknowledgement delay separately on
the authenticated WebSocket.

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

const csrfToken = document.querySelector('meta[name="csrf-token"]').content;
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: {
    MedExSessionHook: createMedExHook({
      Socket,
      socketPath: "/socket",
      topic: el => "signaling:" + el.dataset.encounterId,
      play: "#preview-play",
      disconnect: "#preview-disconnect",
      reconnect: "#preview-reconnect",
      rtcConfig: async el => {
        const response = await fetch("/encounters/" + encodeURIComponent(el.dataset.encounterId) + "/ice");
        if (!response.ok) throw new Error("ICE configuration unavailable");
        return response.json(); // {iceServers, iceTransportPolicy}
      }
    })
  }
});
liveSocket.connect();
```

Channel protocol expected by `createMedExHook`:

1. Joins `topic(el)` with `{ connection_id: crypto.randomUUID() }`, expecting
   `{ session_id }`.
2. Gathers browser ICE candidates and pushes `"offer"` with `{ sdp }`, expecting
   `{ sdp }` answer.
3. Handles `"preview_failed"` and `"preview_replaced"` by closing the peer and
   displaying the appropriate status. The clinician can select Reconnect.
   The hook evaluates `rtcConfig(el)` for each new connection. A host with
   static configuration can pass `iceServers` and `iceTransportPolicy` directly.

## 5. Browser live PCM capture (`pcm_capture.js` & `pcm_worklet.js`)

Call `startPCM` from a user gesture, such as clicking Start. Provide separate
buttons with IDs `finish-capture` and `abort-capture`. Enable Finish from the
recording callback once the server acknowledges the first frame.

```js
import { startPCM } from "/med_ex/pcm_capture.js";

// Host helper opens the authenticated socket and reads the acquisition ID.
const {socket, acquisitionId} = await reserveCapture();
const handle = await startPCM(
  socket,
  "/med_ex/pcm_worklet.js",
  (outcome, measurements) => showCaptureOutcome(acquisitionId, outcome, measurements),
  () => enableFinish(),
  {
    deviceId: diagnosticInput.value,
    onSource: settings => saveLogicalSource(acquisitionId, settings)
  }
);

// Use separate buttons for the two terminal actions.
document.querySelector("#finish-capture").onclick = () => handle.finish();
document.querySelector("#abort-capture").onclick = () => handle.abort();
```

### Source and timing

Offer the browser's `audioinput` devices for separate conversation and
diagnostic input selections. An empty diagnostic selection requests the default
microphone. A selected `deviceId` becomes an exact constraint. The helper asks
for mono with echo cancellation, noise suppression and auto gain disabled.
It calls `onSource` with the track's `getSettings()` fields, its `label`, and
`contextSampleRate`. The callback may return a promise. PCM begins only after
the promise resolves. Unsupported settings are absent. Device IDs identify
logical inputs in the browser's origin. Obtain hardware identity or calibration
separately if relevant.

The audio context runs at 48 kHz. Track `sampleRate` describes the source as
reported by the browser and can differ from `contextSampleRate`. The host can
timestamp the arrival of the first accepted PCM frame and derive duration in
seconds as `sample_count / 48_000`. Store that timing basis and the actor with
the attempt. The continuity verdict covers consecutive browser render samples
from the first emitted frame.

### Live PCM wire protocol and outcome codes

Each binary frame has an 8-byte unsigned big-endian `first_sample` index and
up to 960 mono PCM16LE samples. Send exactly one ordered text `"ack"` after
each successful writer call. The first acknowledgement triggers `onRecording()`.
File synchronization and installation happen at finish.

The delay budget is **250 ms sustained plus 50 ms jitter**. At 20 ms per full
frame this gives 15 frames, plus one for scheduling at the boundary. A frame
takes one of the 16 slots when it is posted from the worklet. The slot stays
occupied through the main-thread queue, WebSocket send queue, and writer until
its acknowledgement reaches the worklet. Another frame can be assembled while
all slots are occupied. The maximum logical buffered wire data, including
8-byte frame headers, is **17 × 1,928 = 32,776 bytes**. This bounds application
audio, independent of browser/OS transport overhead. If a completed frame
cannot be sent, the worklet reports `capture_overflow` and capture closes.

`handle.finish()` sends the short tail, if present, followed by text
`"finish"`. The host replies with a terminal outcome after committing the
recording. `onOutcome(outcome, measurements)` receives `peakBufferedBytes`
(the worklet high-water mark, reported on each frame and worklet termination)
and `maxAckDelayMs` (longest observed interval from WebSocket send to the
corresponding reply, including page scheduling). Premature socket closure
returns the latest reported measurements. On a lost final reply the host can
retrieve the outcome using the acquisition ID.

| Outcome | Meaning |
| --- | --- |
| Host text frame (e.g. `"ready"`, `"capture_failed"`, `"invalid_capture"`) | Terminal response from the host. |
| `"setup_failed"` | Permission, input constraints, source callback, 48 kHz context, worklet or socket setup failed. `startPCM` also rejects. |
| `"capture_source_timeout"` | A contiguous full frame could not be established within one second of startup. |
| `"capture_gap"` | Missing input or a skipped render index after the first full frame. |
| `"capture_overflow"` | A frame was ready while all 16 slots awaited writer acknowledgements. |
| `"invalid_ack"` | An acknowledgement arrived with no outstanding PCM frame. |
| `"source_ended"` | Browser media track ended unexpectedly. |
| `"disconnected"` | WebSocket closed or errored before a terminal host outcome arrived. |
| `"aborted"` | Host browser code called `handle.abort()`. |
