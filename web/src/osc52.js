// OSC 52, the terminal's own "put this on the clipboard" sequence.
//
// Anything that yanks - tmux with set-clipboard on, nvim, a user's own relay -
// can emit it, so honouring it here is what makes copying out of the session
// work without assuming any particular tool is installed. xterm.js has no
// built-in handler, so without this the sequence is simply swallowed.
//
// The base64 is decoded by hand rather than through atob: atob is lenient in
// ways that matter here (it accepts a length no valid encoder produces), and
// this payload comes from whatever is running in the terminal. A malformed
// one should be dropped, not silently turned into mojibake on the clipboard.
(function (D) {
  'use strict';

  var ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function base64Decode(input) {
    if (typeof input !== 'string') return null;
    if (input.length % 4 !== 0) return null;

    var pad = 0;
    while (pad < 2 && input.charAt(input.length - 1 - pad) === '=') pad++;
    var body = input.slice(0, input.length - pad);
    if (body.indexOf('=') !== -1) return null;

    var out = [];
    var acc = 0;
    var bits = 0;
    for (var i = 0; i < body.length; i++) {
      var value = ALPHABET.indexOf(body.charAt(i));
      if (value < 0) return null;
      acc = (acc << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((acc >> bits) & 0xff);
      }
    }
    return new Uint8Array(out);
  }

  // data is everything after "OSC 52;" - a selection name, a semicolon, then
  // base64. Returns null for anything there is nothing to copy from: a "?"
  // query (a read request, which this page does not answer), a clear, or a
  // payload that does not decode.
  function decodeOsc52(data) {
    if (typeof data !== 'string') return null;
    var sep = data.indexOf(';');
    if (sep < 0) return null;
    var payload = data.slice(sep + 1);
    if (payload === '' || payload === '?') return null;
    var bytes = base64Decode(payload);
    if (bytes === null || bytes.length === 0) return null;
    return new TextDecoder().decode(bytes);
  }

  D.osc52 = { base64Decode: base64Decode, decodeOsc52: decodeOsc52 };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
