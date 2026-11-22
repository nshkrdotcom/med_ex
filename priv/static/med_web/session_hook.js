// The exam supplies its Phoenix Socket constructor and server-issued token.
export function createMedExHook({ Socket, socketPath, topic, play, disconnect, reconnect }) {
  return {
    mounted() {
      this.buttons = new AbortController();
      this.audio = this.el.querySelector("audio");
      const options = { signal: this.buttons.signal };

      this.el.querySelector(play).addEventListener("click", () => {
        if (this.pc) this.audio.play().catch(() => {});
        else this.connectPreview();
      }, options);
      this.el.querySelector(disconnect).addEventListener("click", () => {
        this.closePreview("disconnected");
      }, options);
      this.el.querySelector(reconnect).addEventListener("click", () => {
        this.connectPreview();
      }, options);
    },

    async connectPreview() {
      this.closePreview("connecting");
      const pc = new RTCPeerConnection();
      const socket = new Socket(socketPath, { params: { token: this.el.dataset.token } });
      const connectionId = crypto.randomUUID();
      const channel = socket.channel(topic(this.el), {
        connection_id: connectionId
      });

      this.pc = pc;
      this.socket = socket;
      this.channel = channel;
      this.el.medExPeer = pc;
      this.el.dataset.connectionId = connectionId;

      pc.ontrack = ({ track, streams }) => {
        if (this.pc !== pc) return;
        this.audio.srcObject = streams[0] || new MediaStream([track]);
        this.audio.play().catch(() => {});
      };

      pc.onconnectionstatechange = () => {
        if (this.pc === pc) this.el.dataset.state = pc.connectionState;
      };

      channel.onClose(() => {
        if (this.pc === pc) this.closePreview("disconnected");
      });
      channel.onError(() => {
        if (this.pc === pc) this.closePreview("failed");
      });

      try {
        socket.connect();
        const { session_id } = await reply(channel.join());
        if (this.pc !== pc) return;
        this.el.dataset.sessionId = session_id;
        pc.addTransceiver("audio", { direction: "recvonly" });
        await pc.setLocalDescription(await pc.createOffer());
        await gatherCandidates(pc);
        const { sdp } = await reply(channel.push("offer", { sdp: pc.localDescription.sdp }, 7_000));
        await pc.setRemoteDescription({ type: "answer", sdp });
      } catch (error) {
        if (this.pc === pc) {
          this.closePreview("failed");
          this.el.dataset.error = error.message;
        }
      }
    },

    closePreview(state) {
      const { pc, channel, socket } = this;
      this.pc = this.channel = this.socket = null;
      this.el.medExPeer = null;
      this.el.dataset.state = state;
      delete this.el.dataset.error;
      pc?.close();
      channel?.leave().receive("ok", () => socket?.disconnect())
        .receive("error", () => socket?.disconnect())
        .receive("timeout", () => socket?.disconnect());
      if (!channel) socket?.disconnect();
      this.audio.srcObject = null;
    },

    destroyed() {
      this.buttons.abort();
      this.closePreview("disconnected");
    }
  };
}

function reply(push) {
  return new Promise((resolve, reject) => {
    push.receive("ok", resolve)
      .receive("error", ({ reason } = {}) => reject(new Error(reason || "Signaling failed")))
      .receive("timeout", () => reject(new Error("Signaling timed out")));
  });
}

function gatherCandidates(pc) {
  if (pc.iceGatheringState === "complete") return Promise.resolve();

  return new Promise((resolve, reject) => {
    const controller = new AbortController();
    const timer = setTimeout(() => {
      controller.abort();
      reject(new Error("Browser ICE gathering timed out"));
    }, 5_000);

    pc.addEventListener("icegatheringstatechange", () => {
      if (pc.iceGatheringState === "complete") {
        clearTimeout(timer);
        controller.abort();
        resolve();
      }
    }, { signal: controller.signal });
  });
}
