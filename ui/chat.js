/* chat.js -- UI controller for OpenClaw standalone chat
 *
 * Wires Gateway events to DOM. No template literals.
 * Depends on: gateway.js, marked.js, DOMPurify
 */

(function () {
  "use strict";

  // ── DOM refs ──────────────────────────────────────────

  var thread     = document.getElementById("chat-thread");
  var emptyState = document.getElementById("chat-empty");
  var input      = document.getElementById("compose-input");
  var btnSend    = document.getElementById("btn-send");
  var btnStop    = document.getElementById("btn-stop");
  var btnNew     = document.getElementById("btn-new");
  var statusDot  = document.getElementById("status-dot");
  var nameEl     = document.getElementById("assistant-name");
  var themeBtn   = document.getElementById("theme-toggle");

  // ── state ─────────────────────────────────────────────

  var gw           = null;
  var sessionKey   = "main";
  var messages     = [];
  var runId        = null;
  var streamText   = null;
  var assistantName = "Assistant";
  var modelName    = null;
  var isConnected  = false;

  // ── helpers ───────────────────────────────────────────

  function qs(params) {
    var search = window.location.search.replace(/^\?/, "");
    if (!search) return null;
    var parts = search.split("&");
    for (var i = 0; i < parts.length; i++) {
      var kv = parts[i].split("=");
      if (decodeURIComponent(kv[0]) === params) {
        return decodeURIComponent(kv[1] || "");
      }
    }
    return null;
  }

  function uuid() {
    if (typeof crypto !== "undefined" && crypto.randomUUID) {
      return crypto.randomUUID();
    }
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function (c) {
      var r = (Math.random() * 16) | 0;
      var v = c === "x" ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }

  function stripMeta(text) {
    if (!text) return text;
    // remove "Conversation info (untrusted metadata):\n{...}\n[timestamp]" blocks
    return text.replace(/Conversation info \(untrusted metadata\):[\s\S]*?\n\[.*?\]\s*/g, "").trim();
  }

  function extractText(msg) {
    if (!msg) return null;
    var content = msg.content;
    if (typeof content === "string") return stripMeta(content);
    if (Array.isArray(content)) {
      var parts = [];
      for (var i = 0; i < content.length; i++) {
        var block = content[i];
        if (block && block.type === "text" && typeof block.text === "string") {
          parts.push(block.text);
        }
      }
      if (parts.length > 0) return stripMeta(parts.join("\n"));
    }
    if (typeof msg.text === "string") return stripMeta(msg.text);
    return null;
  }

  function renderMarkdown(text) {
    if (!text) return "";
    var html = marked.parse(text);
    return DOMPurify.sanitize(html);
  }

  function formatTime(ts) {
    if (!ts) return "";
    var d = new Date(ts);
    var h = d.getHours();
    var m = d.getMinutes();
    var ampm = h >= 12 ? "PM" : "AM";
    h = h % 12 || 12;
    return h + ":" + (m < 10 ? "0" : "") + m + " " + ampm;
  }

  function scrollToBottom() {
    // slight delay so DOM updates render first
    requestAnimationFrame(function () {
      thread.scrollTop = thread.scrollHeight;
    });
  }

  // ── header status ─────────────────────────────────────
  // states: disconnected, connecting, idle, thinking, responding, error

  var headerStatus = "";

  function setHeaderStatus(status) {
    console.log("[chat] status:", headerStatus, "->", status);
    headerStatus = status;

    // status dot
    var dotState = (status === "idle" || status === "thinking" || status === "responding")
      ? "connected"
      : status === "connecting" ? "connecting" : "disconnected";
    statusDot.className = "status-dot status-dot--" + dotState;
    statusDot.title = dotState.charAt(0).toUpperCase() + dotState.slice(1);

    // header name text + class
    nameEl.className = "chat-header__name";

    if (status === "disconnected") {
      nameEl.textContent = "Disconnected";
      nameEl.classList.add("status--disconnected");
    } else if (status === "connecting") {
      nameEl.textContent = "Connecting";
      nameEl.classList.add("status--connecting");
    } else if (status === "thinking" || status === "responding") {
      nameEl.textContent = "Connected";
    } else if (status === "error") {
      nameEl.textContent = "Error";
      nameEl.classList.add("status--error");
    } else {
      nameEl.textContent = "Connected";
    }
  }

  // ── theme ─────────────────────────────────────────────

  function getStoredTheme() {
    try { return localStorage.getItem("openclaw-theme"); } catch (e) { return null; }
  }

  function setStoredTheme(theme) {
    try { localStorage.setItem("openclaw-theme", theme); } catch (e) { /* noop */ }
  }

  function applyTheme(theme) {
    if (theme === "light") {
      document.documentElement.setAttribute("data-theme", "light");
    } else {
      document.documentElement.removeAttribute("data-theme");
    }
  }

  function currentTheme() {
    return document.documentElement.getAttribute("data-theme") === "light" ? "light" : "dark";
  }

  function toggleTheme(evt) {
    var next = currentTheme() === "dark" ? "light" : "dark";
    var root = document.documentElement;
    var doc = document;

    // view-transition animated switch (same approach as openclaw)
    var canTransition = typeof doc.startViewTransition === "function"
      && !window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    if (canTransition && evt) {
      var x = evt.clientX !== undefined ? evt.clientX / window.innerWidth : 0.5;
      var y = evt.clientY !== undefined ? evt.clientY / window.innerHeight : 0.5;
      root.style.setProperty("--theme-switch-x", (x * 100) + "%");
      root.style.setProperty("--theme-switch-y", (y * 100) + "%");
      root.classList.add("theme-transition");

      try {
        var transition = doc.startViewTransition(function () {
          applyTheme(next);
        });
        if (transition && transition.finished) {
          transition.finished.finally(function () {
            root.classList.remove("theme-transition");
            root.style.removeProperty("--theme-switch-x");
            root.style.removeProperty("--theme-switch-y");
          });
        } else {
          root.classList.remove("theme-transition");
        }
      } catch (e) {
        root.classList.remove("theme-transition");
        applyTheme(next);
      }
    } else {
      applyTheme(next);
    }

    setStoredTheme(next);
  }

  // init theme from storage or system preference
  (function () {
    var stored = getStoredTheme();
    if (stored) {
      applyTheme(stored);
    } else if (window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches) {
      applyTheme("light");
    }
  })();

  themeBtn.addEventListener("click", toggleTheme);

  // ── render ────────────────────────────────────────────

  function renderThread() {
    // clear everything except empty state
    while (thread.firstChild) {
      thread.removeChild(thread.firstChild);
    }

    var allMessages = messages.slice();

    // if streaming, add a temporary assistant message
    if (streamText !== null) {
      allMessages.push({
        role: "assistant",
        content: [{ type: "text", text: streamText }],
        _streaming: true
      });
    }

    if (allMessages.length === 0) {
      thread.appendChild(emptyState);
      emptyState.classList.remove("hidden");
      return;
    }
    emptyState.classList.add("hidden");

    // group consecutive messages by role
    var groups = [];
    var currentGroup = null;
    for (var i = 0; i < allMessages.length; i++) {
      var msg = allMessages[i];
      var role = msg.role || "assistant";
      if (!currentGroup || currentGroup.role !== role) {
        currentGroup = { role: role, messages: [] };
        groups.push(currentGroup);
      }
      currentGroup.messages.push(msg);
    }

    for (var g = 0; g < groups.length; g++) {
      var group = groups[g];
      var isUser = group.role === "user";

      var groupEl = document.createElement("div");
      groupEl.className = "chat-group" + (isUser ? " user" : "");

      // messages column
      var msgsCol = document.createElement("div");
      msgsCol.className = "chat-group-messages";

      for (var m = 0; m < group.messages.length; m++) {
        var msg = group.messages[m];
        var text = extractText(msg);
        if (!text && !msg._streaming) continue;

        var bubble = document.createElement("div");
        bubble.className = "chat-bubble";
        if (msg._streaming) bubble.className += " streaming";

        var textDiv = document.createElement("div");
        textDiv.className = "chat-text";
        textDiv.innerHTML = renderMarkdown(text || "");
        bubble.appendChild(textDiv);

        msgsCol.appendChild(bubble);
      }

      // footer (name + time)
      var lastMsg = group.messages[group.messages.length - 1];
      var footer = document.createElement("div");
      footer.className = "chat-group-footer";

      var senderName = document.createElement("span");
      senderName.className = "chat-sender-name";
      senderName.textContent = isUser ? "You" : "Agent";
      footer.appendChild(senderName);

      if (lastMsg.timestamp) {
        var ts = document.createElement("span");
        ts.className = "chat-group-timestamp";
        ts.textContent = formatTime(lastMsg.timestamp);
        footer.appendChild(ts);
      }

      msgsCol.appendChild(footer);
      groupEl.appendChild(msgsCol);
      thread.appendChild(groupEl);
    }

    scrollToBottom();
  }

  function updateButtons() {
    var streaming = runId !== null;
    if (streaming) {
      btnSend.classList.add("hidden");
      btnStop.classList.remove("hidden");
    } else {
      btnSend.classList.remove("hidden");
      btnStop.classList.add("hidden");
    }
    btnSend.disabled = !isConnected;
    btnNew.disabled = !isConnected;
  }

  // ── actions ───────────────────────────────────────────

  function loadHistory() {
    if (!gw || !gw.connected()) return;
    console.log("[chat] loadHistory request");
    gw.request("chat.history", { sessionKey: sessionKey, limit: 200 })
      .then(function (res) {
        messages = Array.isArray(res.messages) ? res.messages : [];
        console.log("[chat] loadHistory got", messages.length, "messages");
        renderThread();
      })
      .catch(function (err) {
        console.error("[chat] loadHistory error:", err);
      });
  }

  function sendMessage() {
    var text = input.value.trim();
    if (!text || !gw || !gw.connected()) return;

    // optimistic: add user message to thread immediately
    messages.push({
      role: "user",
      content: [{ type: "text", text: text }],
      timestamp: Date.now()
    });

    input.value = "";
    autoGrow();

    runId = uuid();
    streamText = "";
    console.log("[chat] sendMessage runId:", runId, "text:", text.slice(0, 80));
    setHeaderStatus("thinking");
    renderThread();
    updateButtons();

    gw.request("chat.send", {
      sessionKey: sessionKey,
      message: text,
      deliver: false,
      idempotencyKey: runId
    }).then(function (res) {
      console.log("[chat] send OK:", JSON.stringify(res));
      if (res && res.runId) {
        runId = res.runId;
        console.log("[chat] runId updated to server value:", runId);
      }
    }).catch(function (err) {
      console.error("[chat] send error:", err);
      messages.push({
        role: "assistant",
        content: [{ type: "text", text: "Error: " + err.message }],
        timestamp: Date.now()
      });
      runId = null;
      streamText = null;
      setHeaderStatus("error");
      renderThread();
      updateButtons();
      setTimeout(function () { if (!runId) setHeaderStatus("idle"); }, 3000);
    });
  }

  function abortRun() {
    if (!gw || !gw.connected()) return;
    var params = { sessionKey: sessionKey };
    if (runId) params.runId = runId;
    gw.request("chat.abort", params).catch(function (err) {
      console.error("[chat] abort error:", err);
    });
  }

  function resetSession() {
    if (!gw || !gw.connected()) return;
    gw.request("sessions.reset", { key: sessionKey, reason: "new" })
      .then(function () {
        messages = [];
        runId = null;
        streamText = null;
        setHeaderStatus("idle");
        renderThread();
        updateButtons();
        input.focus();
      })
      .catch(function (err) {
        console.error("[chat] reset error:", err);
      });
  }

  // ── gateway events ────────────────────────────────────

  function handleEvent(evt) {
    console.log("[chat] event:", evt.event, evt.payload ? evt.payload.state : "(no payload)");
    if (evt.event !== "chat") return;
    var payload = evt.payload;
    if (!payload || payload.sessionKey !== sessionKey) {
      console.log("[chat] event ignored: sessionKey mismatch", payload && payload.sessionKey, "vs", sessionKey);
      return;
    }

    console.log("[chat] event accepted: state:", payload.state, "runId:", payload.runId, "local:", runId);

    if (payload.state === "delta") {
      var next = extractText(payload.message);
      console.log("[chat] delta text length:", next ? next.length : 0, "streamText was:", streamText ? streamText.length : "null");
      if (typeof next === "string") {
        var current = streamText || "";
        if (!current || next.length >= current.length) {
          streamText = next;
        }
      }
      if (headerStatus === "thinking" && streamText) {
        setHeaderStatus("responding");
      }
      renderThread();
    } else if (payload.state === "final") {
      console.log("[chat] final received, messages before reload:", messages.length);
      streamText = null;
      runId = null;
      setHeaderStatus("idle");
      loadHistory();
      updateButtons();
    } else if (payload.state === "aborted") {
      if (streamText && streamText.trim()) {
        messages.push({
          role: "assistant",
          content: [{ type: "text", text: streamText }],
          timestamp: Date.now()
        });
      }
      streamText = null;
      runId = null;
      setHeaderStatus("idle");
      renderThread();
      updateButtons();
    } else if (payload.state === "error") {
      var errorMsg = payload.errorMessage || "chat error";
      messages.push({
        role: "assistant",
        content: [{ type: "text", text: "Error: " + errorMsg }],
        timestamp: Date.now()
      });
      streamText = null;
      runId = null;
      setHeaderStatus("error");
      renderThread();
      updateButtons();
      setTimeout(function () { if (!runId) setHeaderStatus("idle"); }, 3000);
    }
  }

  // ── compose auto-grow ─────────────────────────────────

  function autoGrow() {
    input.style.height = "auto";
    var next = Math.min(input.scrollHeight, 150);
    input.style.height = Math.max(40, next) + "px";
  }

  input.addEventListener("input", autoGrow);

  input.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  });

  // ── button handlers ───────────────────────────────────

  btnSend.addEventListener("click", sendMessage);
  btnStop.addEventListener("click", abortRun);
  btnNew.addEventListener("click", resetSession);

  // ── init ──────────────────────────────────────────────

  function init() {
    var token = qs("token");
    console.log("[chat] init token:", token ? token.slice(0, 8) + "..." : "(none)");

    // build WebSocket URL from current page location
    var protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    var wsUrl = protocol + "//" + window.location.host;
    console.log("[chat] ws url:", wsUrl);

    // fetch assistant name from config
    fetch("/__openclaw/control-ui-config.json")
      .then(function (res) { return res.json(); })
      .then(function (config) {
        console.log("[chat] config:", JSON.stringify(config));
        if (config.assistantName) {
          assistantName = config.assistantName;
        }
      })
      .catch(function (err) {
        console.log("[chat] config fetch failed (using defaults):", err);
      });

    setHeaderStatus("connecting");

    gw = new Gateway({
      url: wsUrl,
      token: token,
      onHello: function (hello) {
        console.log("[chat] onHello:", JSON.stringify(hello));
        // use the server's resolved session key for event matching
        var defaults = hello && hello.snapshot && hello.snapshot.sessionDefaults;
        if (defaults && defaults.mainSessionKey) {
          console.log("[chat] sessionKey resolved:", sessionKey, "->", defaults.mainSessionKey);
          sessionKey = defaults.mainSessionKey;
        }
        isConnected = true;
        setHeaderStatus("idle");
        updateButtons();
        loadHistory();
        // disable TTS so it doesn't block chat responses
        gw.request("tts.disable", {}).then(function () {
          console.log("[chat] tts disabled");
        }).catch(function (err) {
          console.log("[chat] tts.disable skipped:", err.message);
        });
        // fetch model name for header display
        gw.request("models.list", {}).then(function (res) {
          var models = res && res.models;
          if (Array.isArray(models) && models.length > 0) {
            modelName = models[0].name || models[0].id || null;
            console.log("[chat] model:", modelName);
            if (headerStatus === "idle") setHeaderStatus("idle");
          }
        }).catch(function (err) {
          console.log("[chat] models.list skipped:", err.message);
        });
      },
      onEvent: handleEvent,
      onClose: function (info) {
        console.log("[chat] onClose:", JSON.stringify(info));
        isConnected = false;
        setHeaderStatus("disconnected");
        updateButtons();
      }
    });

    gw.start();
    console.log("[chat] gateway started");
    updateButtons();
  }

  // ── boot ──────────────────────────────────────────────

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

})();
