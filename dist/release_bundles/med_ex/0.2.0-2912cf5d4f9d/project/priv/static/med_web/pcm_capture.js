// The host reserves the acquisition and supplies its authenticated WebSocket.
export async function startPCM(socket, workletURL, onOutcome, onRecording, {deviceId, onSource} = {}) {
  const context = new AudioContext({sampleRate: 48000});
  const sentAt = [];
  const stats = {peakBufferedBytes: 0, maxAckDelayMs: 0};
  let stream;
  let settled = false;
  let recording = false;

  function close(outcome) {
    if (settled) return;
    settled = true;
    stream?.getTracks().forEach(track => track.stop());
    void context.close();
    socket.close();
    onOutcome(outcome, {...stats});
  }

  try {
    if (context.sampleRate !== 48000) throw new Error("48 kHz audio context required");
    stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        ...(deviceId ? {deviceId: {exact: deviceId}} : {}),
        channelCount: {exact: 1}, echoCancellation: {exact: false},
        noiseSuppression: {exact: false}, autoGainControl: {exact: false},
      },
    });
    const [track] = stream.getAudioTracks();
    await context.audioWorklet.addModule(workletURL);
    if (socket.readyState !== WebSocket.OPEN) throw new Error("PCM socket closed");
    // The host may await a reply from its own admission protocol here.
    await onSource?.({...track.getSettings(), label: track.label, contextSampleRate: context.sampleRate});
    if (socket.readyState !== WebSocket.OPEN) throw new Error("PCM socket closed");
    if (track.readyState === "ended") throw new Error("PCM source ended");
    const node = new AudioWorkletNode(context, "med-ex-indexed-pcm", {numberOfOutputs: 0});
    socket.onclose = () => close("disconnected");
    socket.onerror = () => close("disconnected");
    socket.onmessage = ({data}) => {
      if (settled) return;
      if (data !== "ack") return close(data);
      if (!sentAt.length) return close("invalid_ack");
      stats.maxAckDelayMs = Math.max(stats.maxAckDelayMs, performance.now() - sentAt.shift());
      node.port.postMessage("ack");
      if (!recording) {
        recording = true;
        onRecording();
      }
    };
    node.port.onmessage = ({data: {frame, outcome, peakBufferedBytes}}) => {
      if (settled) return;
      stats.peakBufferedBytes = peakBufferedBytes;
      if (socket.readyState !== WebSocket.OPEN) return close("disconnected");
      if (outcome === "finish") return socket.send("finish");
      if (outcome) return close(outcome);
      sentAt.push(performance.now());
      socket.send(frame);
    };
    track.onended = () => close("source_ended");
    context.createMediaStreamSource(stream).connect(node);
    await context.resume();

    return {
      finish: () => node.port.postMessage("finish"),
      abort: () => close("aborted"),
    };
  } catch (error) {
    close("setup_failed");
    throw error;
  }
}
