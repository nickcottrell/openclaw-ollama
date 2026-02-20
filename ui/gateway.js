/* gateway.js -- WebSocket protocol client for OpenClaw gateway
 *
 * Ported from openclaw/ui/src/ui/gateway.ts
 * Token-only auth (no device identity -- local only)
 * No template literals per project convention
 */

(function (root) {
  "use strict";

  // ── helpers ──────────────────────────────────────────────

  function uuid() {
    if (typeof crypto !== "undefined" && crypto.randomUUID) {
      return crypto.randomUUID();
    }
    // fallback
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
      var r = (Math.random() * 16) | 0;
      var v = c === "x" ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }

  // ── constructor ──────────────────────────────────────────

  function Gateway(opts) {
    this._url = opts.url;
    this._token = opts.token || null;
    this._onHello = opts.onHello || null;
    this._onEvent = opts.onEvent || null;
    this._onClose = opts.onClose || null;

    this._ws = null;
    this._pending = {};
    this._closed = false;
    this._connectNonce = null;
    this._connectSent = false;
    this._connectTimer = null;
    this._backoffMs = 800;
    this._lastSeq = null;
  }

  // ── public api ───────────────────────────────────────────

  Gateway.prototype.start = function () {
    this._closed = false;
    this._connect();
  };

  Gateway.prototype.stop = function () {
    this._closed = true;
    if (this._ws) {
      this._ws.close();
      this._ws = null;
    }
    this._flushPending("gateway client stopped");
  };

  Gateway.prototype.connected = function () {
    return this._ws && this._ws.readyState === WebSocket.OPEN;
  };

  Gateway.prototype.request = function (method, params) {
    var self = this;
    if (!self._ws || self._ws.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error("gateway not connected"));
    }
    var id = uuid();
    var frame = JSON.stringify({
      type: "req",
      id: id,
      method: method,
      params: params
    });
    var promise = new Promise(function (resolve, reject) {
      self._pending[id] = { resolve: resolve, reject: reject };
    });
    self._ws.send(frame);
    return promise;
  };

  // ── internal ─────────────────────────────────────────────

  Gateway.prototype._connect = function () {
    if (this._closed) return;
    var self = this;
    var ws = new WebSocket(this._url);
    this._ws = ws;

    ws.addEventListener("open", function () {
      console.log("[gw] ws open");
      self._queueConnect();
    });

    ws.addEventListener("message", function (ev) {
      self._handleMessage(String(ev.data || ""));
    });

    ws.addEventListener("close", function (ev) {
      var reason = String(ev.reason || "");
      console.log("[gw] ws close code:", ev.code, "reason:", reason);
      self._ws = null;
      self._flushPending("gateway closed (" + ev.code + "): " + reason);
      if (self._onClose) {
        self._onClose({ code: ev.code, reason: reason });
      }
      self._scheduleReconnect();
    });

    ws.addEventListener("error", function (ev) {
      console.error("[gw] ws error:", ev);
    });
  };

  Gateway.prototype._scheduleReconnect = function () {
    if (this._closed) return;
    var delay = this._backoffMs;
    this._backoffMs = Math.min(this._backoffMs * 1.7, 15000);
    var self = this;
    setTimeout(function () { self._connect(); }, delay);
  };

  Gateway.prototype._flushPending = function (msg) {
    var keys = Object.keys(this._pending);
    for (var i = 0; i < keys.length; i++) {
      this._pending[keys[i]].reject(new Error(msg));
    }
    this._pending = {};
  };

  Gateway.prototype._queueConnect = function () {
    this._connectNonce = null;
    this._connectSent = false;
    if (this._connectTimer !== null) {
      clearTimeout(this._connectTimer);
    }
    var self = this;
    this._connectTimer = setTimeout(function () {
      self._sendConnect();
    }, 750);
  };

  Gateway.prototype._sendConnect = function () {
    if (this._connectSent) return;
    console.log("[gw] sendConnect nonce:", this._connectNonce ? this._connectNonce.slice(0, 8) + "..." : "(none)");
    this._connectSent = true;
    if (this._connectTimer !== null) {
      clearTimeout(this._connectTimer);
      this._connectTimer = null;
    }

    var auth = this._token ? { token: this._token } : undefined;
    var params = {
      minProtocol: 3,
      maxProtocol: 3,
      client: {
        id: "openclaw-control-ui",
        version: "standalone-1.0",
        platform: navigator.platform || "web",
        mode: "webchat"
      },
      role: "operator",
      scopes: ["operator.admin", "operator.read", "operator.write"],
      caps: [],
      auth: auth,
      userAgent: navigator.userAgent,
      locale: navigator.language
    };

    var self = this;
    console.log("[gw] connect request:", JSON.stringify(params, null, 2));
    this.request("connect", params)
      .then(function (hello) {
        console.log("[gw] hello-ok:", JSON.stringify(hello));
        self._backoffMs = 800;
        if (self._onHello) self._onHello(hello);
      })
      .catch(function (err) {
        console.error("[gw] connect failed:", err);
        if (self._ws) self._ws.close(4008, "connect failed");
      });
  };

  Gateway.prototype._handleMessage = function (raw) {
    var parsed;
    try { parsed = JSON.parse(raw); } catch (e) { return; }

    console.log("[gw] msg:", parsed.type, parsed.method || parsed.event || "", parsed.ok !== undefined ? "ok:" + parsed.ok : "");

    // event frame
    if (parsed.type === "event") {
      // connect.challenge: extract nonce, trigger auth
      if (parsed.event === "connect.challenge") {
        var payload = parsed.payload || {};
        var nonce = typeof payload.nonce === "string" ? payload.nonce : null;
        if (nonce) {
          this._connectNonce = nonce;
          this._sendConnect();
        }
        return;
      }
      // sequence gap detection
      var seq = typeof parsed.seq === "number" ? parsed.seq : null;
      if (seq !== null && this._lastSeq !== null && seq > this._lastSeq + 1) {
        // gap detected -- we just log for now
        console.warn("[gateway] seq gap: expected " + (this._lastSeq + 1) + ", got " + seq);
      }
      if (seq !== null) this._lastSeq = seq;
      if (this._onEvent) {
        try { this._onEvent(parsed); } catch (err) {
          console.error("[gateway] event handler error:", err);
        }
      }
      return;
    }

    // response frame
    if (parsed.type === "res") {
      var p = this._pending[parsed.id];
      if (!p) return;
      delete this._pending[parsed.id];
      if (parsed.ok) {
        p.resolve(parsed.payload);
      } else {
        var errMsg = (parsed.error && parsed.error.message) ? parsed.error.message : "request failed";
        p.reject(new Error(errMsg));
      }
      return;
    }

    // hello-ok is delivered as a response to the "connect" request,
    // so it flows through the res handler above.
  };

  // ── export ───────────────────────────────────────────────

  root.Gateway = Gateway;

})(window);
