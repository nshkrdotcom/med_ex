// MedWeb reusable browser signaling & reconnect hook asset.
// Shipped inside priv/static/med_web/session_hook.js and verified through Weld projection.
export const MedSessionHook = {
  mounted() {
    this.connectionId = this.el.dataset.connectionId || crypto.randomUUID();
    this.sessionId = this.el.dataset.sessionId;
  },
  reconnected() {
    this.connectionId = crypto.randomUUID();
    this.pushEvent("med_session_rejoin", {
      session_id: this.sessionId,
      connection_id: this.connectionId
    });
  }
};
