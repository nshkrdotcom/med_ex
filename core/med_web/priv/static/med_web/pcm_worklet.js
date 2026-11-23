// One extra frame covers render-quantum and acknowledgement ordering at the boundary.
const frameSamples = 960;
const frameBytes = 8 + frameSamples * 2;
const frameMs = frameSamples / 48000 * 1000;
const maxInFlight = Math.ceil((250 + 50) / frameMs) + 1;

class IndexedPCM extends AudioWorkletProcessor {
  frame = new ArrayBuffer(frameBytes);
  view = new DataView(this.frame);
  used = 0;
  firstSourceFrame;
  nextSourceFrame;
  frameIndex;
  startedAt;
  established = false;
  inFlight = 0;
  peakBufferedBytes = 0;
  stopped = false;

  constructor() {
    super();
    this.port.onmessage = ({data}) => {
      if (this.stopped) return;
      if (data === "ack" && this.inFlight > 0) this.inFlight--;
      if (data === "finish") {
        if (this.used && !this.emit()) return;
        this.stop("finish");
      }
    };
  }

  recordPeak() {
    // Every outstanding frame is full until the final short tail. Include its
    // wire header and the currently assembled samples before transferring it.
    const queued = this.used ? 8 + this.used * 2 : 0;
    this.peakBufferedBytes = Math.max(this.peakBufferedBytes, this.inFlight * frameBytes + queued);
  }

  stop(outcome) {
    this.stopped = true;
    this.port.postMessage({outcome, peakBufferedBytes: this.peakBufferedBytes});
    return false;
  }

  emit() {
    this.recordPeak();
    if (this.inFlight === maxInFlight) return this.stop("capture_overflow");
    this.view.setBigUint64(0, BigInt(this.frameIndex));
    const frame = new Uint8Array(this.frame, 0, 8 + this.used * 2);
    this.port.postMessage({frame, peakBufferedBytes: this.peakBufferedBytes}, [this.frame]);
    this.established = true;
    this.inFlight++;
    this.used = 0;
    this.frame = new ArrayBuffer(frameBytes);
    this.view = new DataView(this.frame);
    return true;
  }

  process(inputs) {
    if (this.stopped) return false;
    this.startedAt ??= currentFrame;
    if (!this.established && currentFrame - this.startedAt >= sampleRate) {
      return this.stop("capture_source_timeout");
    }
    const samples = inputs[0]?.[0];
    if (!samples?.length || (this.nextSourceFrame !== undefined && currentFrame !== this.nextSourceFrame)) {
      if (this.established) return this.stop("capture_gap");
      this.used = 0;
      this.firstSourceFrame = undefined;
      this.nextSourceFrame = undefined;
      if (!samples?.length) return true;
    }
    this.firstSourceFrame ??= currentFrame;
    this.nextSourceFrame = currentFrame + samples.length;

    for (const [offset, sample] of samples.entries()) {
      if (!this.used) this.frameIndex = currentFrame + offset - this.firstSourceFrame;
      const clipped = Math.max(-1, Math.min(1, sample));
      this.view.setInt16(8 + 2 * this.used++, Math.round(clipped * (clipped < 0 ? 32768 : 32767)), true);
      if (this.used === frameSamples && !this.emit()) return false;
    }
    this.recordPeak();
    return true;
  }
}

registerProcessor("med-ex-indexed-pcm", IndexedPCM);
