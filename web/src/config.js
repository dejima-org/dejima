// Page configuration: what arrives in ttyd's SET_PREFERENCES message (its
// -t key=value options), and the query-string overrides that let one client
// deviate without touching server config.
//
// Requires keys.js, for the chord parsing parsePrefix shares with sticky Ctrl.
(function (D) {
  'use strict';

  var DEFAULT_TMUX_PREFIX = 'C-b';

  // Options this page consumes itself. Everything else in the preferences is
  // an xterm.js option and is handed to the terminal untouched, which is how
  // the existing TTYD_FONT_SIZE knob keeps working with no code here knowing
  // about it. isWindows is ttyd's own, always present, and not an xterm option.
  var PAGE_KEYS = ['tmuxPrefix'];
  var IGNORED_KEYS = ['isWindows'];

  // "C-b" -> "\x02", the byte tmux is actually listening for. Deliberately
  // narrow: a prefix that does not parse must be reported, not silently
  // replaced with the default, or a typo'd config looks like a broken button.
  function parsePrefix(spec) {
    if (typeof spec !== 'string') return null;
    var trimmed = spec.trim();
    if (trimmed.length < 3) return null;
    if (trimmed.charAt(1) !== '-') return null;
    var modifier = trimmed.charAt(0).toUpperCase();
    if (modifier !== 'C') return null;
    return D.keys.ctrlSequence(trimmed.slice(2));
  }

  function splitPreferences(prefs) {
    var page = {};
    var terminal = {};
    if (prefs && typeof prefs === 'object') {
      Object.keys(prefs).forEach(function (key) {
        if (PAGE_KEYS.indexOf(key) !== -1) page[key] = prefs[key];
        else if (IGNORED_KEYS.indexOf(key) === -1) terminal[key] = prefs[key];
      });
    }
    return { page: page, terminal: terminal };
  }

  // The toolbar is for touch, so a coarse pointer is the default answer. The
  // override exists because the pointer type is not always the question being
  // asked: a desktop browser driving a demo, or a phone where the toolbar is
  // in the way of a screenshot.
  function toolbarWanted(search, coarsePointer) {
    var params = new URLSearchParams(search || '');
    var value = params.get('toolbar');
    if (value === '1') return true;
    if (value === '0') return false;
    return !!coarsePointer;
  }

  D.config = {
    DEFAULT_TMUX_PREFIX: DEFAULT_TMUX_PREFIX,
    PAGE_KEYS: PAGE_KEYS,
    parsePrefix: parsePrefix,
    splitPreferences: splitPreferences,
    toolbarWanted: toolbarWanted
  };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
