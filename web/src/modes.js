// Tracks the DEC private modes that decide how a gesture must be translated.
//
// xterm.js knows all of this internally and exposes none of it, so the only
// way to see a mode change is to watch the sequences go past. Every handler
// here returns false, which is xterm's "not handled" - the sequence then
// continues to xterm's own parser and takes effect as normal. Returning true
// would make this file the terminal's mouse implementation by accident.
(function (D) {
  'use strict';

  var TRACKED = [1, 1000, 1002, 1003, 1006, 2004];

  function createModeTracker() {
    var state = {};

    function clear() {
      for (var i = 0; i < TRACKED.length; i++) state[TRACKED[i]] = false;
    }
    clear();

    // params arrive from xterm as (number | number[])[] - an array element is a
    // parameter with sub-parameters, e.g. "1002:1", whose mode is still the
    // first value.
    function apply(params, value) {
      for (var i = 0; i < params.length; i++) {
        var p = params[i];
        var mode = Array.isArray(p) ? p[0] : p;
        if (mode in state) state[mode] = value;
      }
      return false;
    }

    return {
      set: function (params) { return apply(params, true); },
      reset: function (params) { return apply(params, false); },
      clear: clear,
      isSet: function (mode) { return state[mode] === true; },
      // Any of the three means the application has taken the mouse. 1000 is
      // click-only, 1002 adds motion while a button is down, 1003 adds motion
      // always; for "should this gesture go to the application at all" they are
      // the same answer.
      mouseReporting: function () { return state[1000] || state[1002] || state[1003]; },
      motionReporting: function () { return state[1002] || state[1003]; },
      sgrEncoding: function () { return state[1006]; },
      bracketedPaste: function () { return state[2004]; },
      // DECCKM. Not a mouse mode, but the toolbar's arrow buttons are the
      // only arrow keys a phone has, and an application that has switched the
      // cursor keys to their SS3 form is entitled to receive that form.
      applicationCursor: function () { return state[1]; }
    };
  }

  D.modes = { TRACKED: TRACKED, createModeTracker: createModeTracker };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
