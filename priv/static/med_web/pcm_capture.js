// The host supplies an open, authenticated binary WebSocket.
export async function startPCM(socket, workletURL, onOutcome, onRecording) {
  const context = new AudioContext({sampleRate: 48000});
  let stream;
  let settled = false;
  let recording = false;

  function close(outcome) {
    if (settled) return;
    settled = true;
    stream?.getTracks().forEach(track => track.stop());
    void context.close();
    socket.close();
    onOutcome(outcome);
  }

  try {
    if (context.sampleRate !== 48000) throw new Error("48 kHz audio context required");
    stream = await navigator.mediaDevices.getUserMedia({
      audio: {channelCount: {exact: 1}, echoCancellation: {exact: false},
        noiseSuppression: {exact: false}, autoGainControl: {exact: false}},
    });
    await context.audioWorklet.addModule(workletURL);
    if (socket.readyState !== WebSocket.OPEN) throw new Error("PCM socket closed");
    const node = new AudioWorkletNode(context, "med-ex-indexed-pcm", {numberOfOutputs: 0});
    socket.onclose = () => close("disconnected");
    socket.onerror = () => close("disconnected");
    socket.onmessage = ({data}) => {
      if (data !== "ack") return close(data);
      node.port.postMessage("ack");
      if (!recording) {
        recording = true;
        onRecording();
      }
    };
    node.port.onmessage = ({data}) => {
      if (socket.readyState !== WebSocket.OPEN) close("disconnected");
      else if (["capture_overflow", "capture_gap", "capture_source_timeout"].includes(data)) close(data);
      else socket.send(data);
    };
    stream.getTracks().forEach(track => { track.onended = () => close("source_ended"); });
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
