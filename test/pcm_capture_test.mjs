import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";

// Import the shipped browser ES module without imposing a package type on hosts.
const asset = await readFile(new URL("../priv/static/med_web/pcm_capture.js", import.meta.url));
const {startPCM} = await import("data:text/javascript;base64," + asset.toString("base64"));

test("an exact logical input and observed settings precede PCM, and surplus ACKs fail", async () => {
  const settings = {deviceId: "origin-scoped", sampleRate: 44100, channelCount: 1};
  const track = {label: "Diagnostic microphone", getSettings: () => settings, stop() {}};
  let constraints, node, connected = false, released, observed, recording = false, terminal;
  const admission = new Promise(resolve => { released = resolve; });
  let sourceOffered;
  const offered = new Promise(resolve => { sourceOffered = resolve; });
  Object.defineProperty(globalThis, "navigator", {configurable: true, value: {
    mediaDevices: {async getUserMedia(request) {
      constraints = request.audio;
      return {getAudioTracks: () => [track], getTracks: () => [track]};
    }},
  }});
  globalThis.AudioContext = class {
    sampleRate = 48000;
    audioWorklet = {async addModule() {}};
    createMediaStreamSource() { return {connect() { connected = true; }}; }
    async resume() {}
    async close() {}
  };
  globalThis.AudioWorkletNode = class {
    port = {postMessage() {}};
    constructor() { node = this; }
  };
  globalThis.WebSocket = {OPEN: 1};
  const socket = {readyState: 1, send() {}, close() {}};
  const pending = startPCM(socket, "/worklet.js", (outcome, stats) => { terminal = {outcome, stats}; },
    () => { recording = true; }, {deviceId: settings.deviceId, onSource: async source => {
      observed = source;
      sourceOffered();
      await admission;
    }});
  await offered;
  assert.deepEqual(constraints.deviceId, {exact: settings.deviceId});
  assert.deepEqual(observed, {...settings, label: track.label, contextSampleRate: 48000});
  assert.equal(connected, false);
  released();
  await pending;
  assert.equal(connected, true);

  node.port.onmessage({data: {frame: new Uint8Array(1928), peakBufferedBytes: 1928}});
  socket.onmessage({data: "ack"});
  assert.equal(recording, true);
  socket.onmessage({data: "ack"});
  assert.equal(terminal.outcome, "invalid_ack");
  assert.equal(terminal.stats.peakBufferedBytes, 1928);
  assert.ok(terminal.stats.maxAckDelayMs >= 0);
});
