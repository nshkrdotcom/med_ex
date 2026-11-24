// MedWeb reusable browser RTCPeerConnection signaling & reconnect hook asset.
// Shipped inside priv/static/med_web/session_hook.js and verified through Weld projection.
export const MedSessionHook = {
  mounted() {
    this.sessionId = this.el.dataset.sessionId;
    this.peerId = this.el.dataset.peerId || "browser_peer";
    this.role = this.el.dataset.role || "clinician";
    this.connectPeer();
  },

  async connectPeer() {
    this.connectionId = this.el.dataset.connectionId || crypto.randomUUID();
    this.pc = new RTCPeerConnection({ iceServers: [] });

    this.pc.onicecandidate = (event) => {
      if (event.candidate) {
        this.pushEvent("med_ice_candidate", {
          session_id: this.sessionId,
          connection_id: this.connectionId,
          candidate: event.candidate.toJSON()
        });
      }
    };

    this.pc.onconnectionstatechange = () => {
      this.pushEvent("med_peer_state", {
        session_id: this.sessionId,
        peer_id: this.peerId,
        connection_id: this.connectionId,
        state: this.pc.connectionState
      });
    };

    this.handleEvent("med_sdp_answer", async ({ sdp }) => {
      await this.pc.setRemoteDescription({ type: "answer", sdp });
    });

    this.handleEvent("med_remote_ice", async ({ candidate }) => {
      await this.pc.addIceCandidate(candidate);
    });

    this.pushEvent("med_session_join", {
      session_id: this.sessionId,
      peer_id: this.peerId,
      connection_id: this.connectionId,
      role: this.role
    });
  },

  reconnected() {
    if (this.pc) {
      this.pc.close();
    }
    this.connectPeer();
  },

  destroyed() {
    if (this.pc) {
      this.pc.close();
    }
  }
};
