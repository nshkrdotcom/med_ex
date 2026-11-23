class IndexedPCM extends AudioWorkletProcessor {
  frame = new ArrayBuffer(1928);
  view = new DataView(this.frame);
  used = 0;
  firstSourceFrame;
  frameIndex;
  emptySince;
  startedAt;
  emitted = false;
  credits = 8;
  stopped = false;
  nextSourceFrame;

  constructor() {
    super();
    this.port.onmessage = ({data}) => {
      if (this.stopped) return;
      if (data === "ack") this.credits++;
      if (data === "finish") {
        if (this.emptySince !== undefined) return this.abort("capture_gap");
        if (this.used && !this.emit()) return;
        this.stopped = true;
        this.port.postMessage("finish");
      }
    };
  }

  abort(reason) {
    this.stopped = true;
    this.port.postMessage(reason);
    return false;
  }

  emit() {
    if (!this.credits) return this.abort("capture_overflow");
    this.view.setBigUint64(0, BigInt(this.frameIndex));
    const frame = this.used === 960 ? this.frame : this.frame.slice(0, 8 + this.used * 2);
    this.emitted = true;
    this.credits--;
    this.used = 0;
    this.frame = new ArrayBuffer(1928);
    this.view = new DataView(this.frame);
    this.port.postMessage(frame, [frame]);
    return true;
  }

  process(inputs) {
    if (this.stopped) return false;
    this.startedAt ??= currentFrame;
    if (!this.emitted && currentFrame - this.startedAt >= sampleRate) {
      return this.abort("capture_source_timeout");
    }
    const samples = inputs[0]?.[0];
    if (!samples?.length) {
      this.emptySince ??= currentFrame;
      return currentFrame - this.emptySince < sampleRate || this.abort("capture_source_timeout");
    }
    this.emptySince = undefined;
    if (this.nextSourceFrame !== undefined && currentFrame !== this.nextSourceFrame) {
      if (this.emitted) return this.abort("capture_gap");
      this.used = 0;
      this.firstSourceFrame = currentFrame;
    }
    this.firstSourceFrame ??= currentFrame;
    this.nextSourceFrame = currentFrame + samples.length;

    for (const [offset, sample] of samples.entries()) {
      if (!this.used) this.frameIndex = currentFrame + offset - this.firstSourceFrame;
      const clipped = Math.max(-1, Math.min(1, sample));
      this.view.setInt16(8 + 2 * this.used++, Math.round(clipped * (clipped < 0 ? 32768 : 32767)), true);
      if (this.used === 960 && !this.emit()) return false;
    }
    return true;
  }
}

registerProcessor("med-ex-indexed-pcm", IndexedPCM);
