// ttyd's WebSocket protocol, as of 1.7.x (src/server.h, src/protocol.c).
//
// The handshake is GET <base>/token, then a WebSocket to <base>/ws with the
// "tty" subprotocol, then a JSON message naming the token and the initial
// size - which is also what makes ttyd spawn the process, so it is not
// optional even when ttyd has no credential to check.
//
// Every later message carries its type in the first byte. It is not a
// committed public API, so a ttyd upgrade is a thing to re-check.
(function (D) {
  'use strict';

  // client -> server
  var INPUT = 0x30;          // '0'
  var RESIZE_TERMINAL = 0x31; // '1'
  // server -> client
  var OUTPUT = '0';
  var SET_WINDOW_TITLE = '1';
  var SET_PREFERENCES = '2';

  var RECONNECT_MIN_MS = 500;
  var RECONNECT_MAX_MS = 10000;

  // Relative to the page's own URL, so a reverse proxy serving ttyd under a
  // --base-path needs no configuration here.
  //
  // location.search is carried onto the WebSocket URL deliberately: ttyd's
  // --url-arg reads its arg= fragments off the WebSocket request and not off
  // the page load, so dropping the query here would silently break dejima's
  // notification deep link (?arg=<run-id>) while the terminal still worked.
  function endpoints(location) {
    var dir = location.pathname.replace(/[^/]*$/, '');
    var scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return {
      token: dir + 'token',
      ws: scheme + '//' + location.host + dir + 'ws' + (location.search || '')
    };
  }

  // opts: {location, onOutput(Uint8Array), onTitle(string), onPreferences(obj),
  //        onStatus(string), size() -> {cols, rows}}
  function createClient(opts) {
    var urls = endpoints(opts.location);
    var encoder = new TextEncoder();
    var decoder = new TextDecoder();
    var socket = null;
    var backoff = RECONNECT_MIN_MS;
    var timer = null;

    function open() {
      return socket && socket.readyState === WebSocket.OPEN;
    }

    function sendBytes(type, payload) {
      if (!open()) return;
      var frame = new Uint8Array(payload.length + 1);
      frame[0] = type;
      frame.set(payload, 1);
      socket.send(frame);
    }

    function sendInput(text) {
      sendBytes(INPUT, encoder.encode(text));
    }

    // For what xterm calls binary data - mouse reports and the like, where the
    // string is a byte sequence and encoding it as UTF-8 would corrupt it.
    function sendBinary(text) {
      var bytes = new Uint8Array(text.length);
      for (var i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
      sendBytes(INPUT, bytes);
    }

    function sendResize(cols, rows) {
      sendBytes(RESIZE_TERMINAL, encoder.encode(JSON.stringify({ columns: cols, rows: rows })));
    }

    function onMessage(event) {
      var data = new Uint8Array(event.data);
      if (data.length === 0) return;
      var command = String.fromCharCode(data[0]);
      var rest = data.subarray(1);
      if (command === OUTPUT) {
        // Handed on as bytes rather than a string: a UTF-8 character split
        // across two frames only reassembles correctly inside xterm's decoder.
        opts.onOutput(rest);
      } else if (command === SET_WINDOW_TITLE) {
        opts.onTitle(decoder.decode(rest));
      } else if (command === SET_PREFERENCES) {
        var text = decoder.decode(rest);
        var prefs = null;
        try {
          prefs = JSON.parse(text);
        } catch (e) {
          prefs = null;
        }
        opts.onPreferences(prefs);
      }
    }

    function scheduleReconnect() {
      if (timer !== null) return;
      timer = setTimeout(function () {
        timer = null;
        connect();
      }, backoff);
      backoff = Math.min(backoff * 2, RECONNECT_MAX_MS);
    }

    function connect() {
      opts.onStatus('connecting');
      fetch(urls.token, { credentials: 'same-origin' })
        .then(function (response) { return response.json(); })
        .then(function (body) { start(body && body.token ? body.token : ''); })
        .catch(function () {
          opts.onStatus('closed');
          scheduleReconnect();
        });
    }

    function start(token) {
      socket = new WebSocket(urls.ws, ['tty']);
      socket.binaryType = 'arraybuffer';
      socket.onopen = function () {
        backoff = RECONNECT_MIN_MS;
        var size = opts.size();
        // ttyd only spawns the process once this arrives, so it goes first
        // whether or not there is a credential to authenticate.
        socket.send(JSON.stringify({ AuthToken: token, columns: size.cols, rows: size.rows }));
        opts.onStatus('open');
      };
      socket.onmessage = onMessage;
      socket.onerror = function () { /* onclose follows, and handles it */ };
      socket.onclose = function () {
        socket = null;
        opts.onStatus('closed');
        scheduleReconnect();
      };
    }

    return {
      connect: connect,
      urls: urls,
      isOpen: open,
      sendInput: sendInput,
      sendBinary: sendBinary,
      sendResize: sendResize
    };
  }

  D.protocol = { endpoints: endpoints, createClient: createClient };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
