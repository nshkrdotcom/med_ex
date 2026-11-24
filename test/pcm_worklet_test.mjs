import assert from "node:assert/strict";
import test from "node:test";

let Worklet;
globalThis.sampleRate = 48000;
globalThis.AudioWorkletProcessor = class { port = {}; };
globalThis.registerProcessor = (_name, processor) => { Worklet = processor; };
await import("../priv/static/med_web/pcm_worklet.js");

const signal = [-1, 0, 1, 0.5, -0.5];
const pcm16 = [-32768, 0, 32767, 16384, -16384];

function capture(sampleCount, delay) {
  const worklet = new Worklet();
  const frames = [];
  const acknowledgements = [];
  let terminal;

  worklet.port.postMessage = ({frame, outcome, peakBufferedBytes}) => {
    if (outcome) {
      terminal = {outcome, peakBufferedBytes};
      return;
    }
    frames.push(Buffer.from(frame));
    // WebSocket replies arrive in order, even when the writer's delay varies.
    const due = currentFrame + Math.round(delay(frames.length) * sampleRate / 1000);
    acknowledgements.push(Math.max(acknowledgements.at(-1) ?? 0, due));
  };

  for (let start = 0; start < sampleCount && !terminal; start += 128) {
    globalThis.currentFrame = start;
    while (acknowledgements.length && acknowledgements[0] <= start) {
      acknowledgements.shift();
      worklet.port.onmessage({data: "ack"});
    }
    const samples = Float32Array.from({length: Math.min(128, sampleCount - start)},
      (_, i) => signal[(start + i) % signal.length]);
    worklet.process([[samples]]);
  }
  worklet.port.onmessage({data: "finish"});
  return {frames, terminal};
}

test("250 ms acknowledgements with up to 50 ms jitter retain every sample and the tail", () => {
  const count = 48641;
  for (const delay of [() => 300, n => 250 + n % 51]) {
    const {frames, terminal} = capture(count, delay);
    assert.equal(terminal.outcome, "finish");
    assert.ok(terminal.peakBufferedBytes <= 17 * 1928);
    assert.ok(terminal.peakBufferedBytes >= 12 * 1928);
    let index = 0;
    for (const frame of frames) {
      assert.equal(frame.readBigUInt64BE(), BigInt(index));
      assert.equal(frame.length, 8 + 2 * Math.min(960, count - index));
      for (let offset = 8; offset < frame.length; offset += 2) {
        assert.equal(frame.readInt16LE(offset), pcm16[index++ % pcm16.length]);
      }
    }
    assert.equal(index, count);
  }
});

test("beyond the window capture ends with overload before sending finish", () => {
  const {frames, terminal} = capture(48000, () => 500);
  assert.equal(frames.length, 16);
  assert.deepEqual(terminal, {outcome: "capture_overflow", peakBufferedBytes: 17 * 1928});
});

test("a gap after capture starts fails immediately with credits available", () => {
  const worklet = new Worklet();
  const messages = [];
  worklet.port.postMessage = data => messages.push(data);
  globalThis.currentFrame = 100;
  worklet.process([[new Float32Array(960)]]);
  globalThis.currentFrame += 961;
  assert.equal(worklet.process([[new Float32Array(128)]]), false);
  assert.equal(messages.at(-1).outcome, "capture_gap");
});

test("spurious acknowledgements cannot expand the worklet window", () => {
  const worklet = new Worklet();
  const messages = [];
  worklet.port.postMessage = data => messages.push(data);
  for (let i = 0; i < 50; i++) worklet.port.onmessage({data: "ack"});
  for (let i = 0; i < 17; i++) {
    globalThis.currentFrame = i * 960;
    worklet.process([[new Float32Array(960)]]);
  }
  assert.equal(messages.at(-1).outcome, "capture_overflow");
});
