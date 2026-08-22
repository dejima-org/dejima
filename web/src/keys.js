// Sticky Ctrl: the control code a key would produce with Ctrl held, plus the
// three-state latch the toolbar button drives.
//
// A phone keyboard has no Ctrl. Rather than ask for a third-party keyboard,
// the toolbar arms a latch and the next keystroke is transformed here.
(function (D) {
  'use strict';

  // The control codes that are not simply letter-minus-64. "Space" is the
  // KeyboardEvent.key a phone keyboard sends for the space bar in some
  // layouts; " " is what most send.
  var SPECIAL = {
    '@': '\x00',
    ' ': '\x00',
    'Space': '\x00',
    '[': '\x1b',
    '\\': '\x1c',
    ']': '\x1d',
    '^': '\x1e',
    '_': '\x1f',
    '?': '\x7f'
  };

  // null means "this key has no control code" - Ctrl+ArrowUp is a real chord
  // in some applications, but it is not a byte, so the caller must let the
  // keystroke through untouched rather than swallow it.
  function ctrlSequence(key) {
    if (typeof key !== 'string' || key === '') return null;
    if (Object.prototype.hasOwnProperty.call(SPECIAL, key)) return SPECIAL[key];
    // The config schema accepts "space" in any case (see ttyd_tmux_prefix),
    // so a named key matches case-insensitively here too. Without this,
    // `C-space` passed validation on the host and was then rejected on the
    // page, which silently fell back to C-b - the outcome the launch-time
    // refusal exists to prevent.
    var named = key.charAt(0).toUpperCase() + key.slice(1).toLowerCase();
    if (Object.prototype.hasOwnProperty.call(SPECIAL, named)) return SPECIAL[named];
    if (key.length !== 1) return null;
    var code = key.toUpperCase().charCodeAt(0);
    if (code < 0x41 || code > 0x5a) return null;
    return String.fromCharCode(code - 0x40);
  }

  // off -> once -> locked -> off. "once" is the common case (Ctrl+C), "locked"
  // is for a run of them (Ctrl+W then Ctrl+W in an editor), and both are
  // reachable without a modal UI: it is the same button.
  function createCtrlLatch() {
    var state = 'off';
    return {
      state: function () { return state; },
      armed: function () { return state !== 'off'; },
      tap: function () {
        state = state === 'off' ? 'once' : state === 'once' ? 'locked' : 'off';
        return state;
      },
      consume: function () {
        if (state === 'once') state = 'off';
        return state;
      },
      reset: function () { state = 'off'; return state; }
    };
  }

  D.keys = { ctrlSequence: ctrlSequence, createCtrlLatch: createCtrlLatch };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
