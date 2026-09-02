// Page configuration: what arrives in ttyd's SET_PREFERENCES message (its
// -t key=value options), and the query-string overrides that let one client
// deviate without touching server config.
//
// Requires keys.js, for the chord parsing parsePrefix shares with sticky Ctrl.
(function (D) {
  'use strict';

  var DEFAULT_TMUX_PREFIX = 'C-b';

  // Rows of finger travel per scroll notch, where the notch goes to the
  // application rather than to this page's own scrollback. Five because that
  // is what a notch buys there: stock tmux binds WheelUpPane in copy-mode to
  // `send -X -N 5 scroll-up`, and a full-screen application picks its own
  // figure in the same range. One row per notch therefore moved the screen
  // about five times faster than the finger, which is why placing a line at
  // the bottom of the screen took several tries.
  var DEFAULT_SCROLL_STEP = 5;

  // Options this page consumes itself. Everything else in the preferences is
  // an xterm.js option and is handed to the terminal untouched, which is how
  // the existing TTYD_FONT_SIZE knob keeps working with no code here knowing
  // about it. isWindows is ttyd's own, always present, and not an xterm option.
  var PAGE_KEYS = ['tmuxPrefix', 'focusOnTap', 'buttonColors', 'scrollStep'];
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

  // Whether tapping the terminal should raise the soft keyboard.
  //
  // Off by default where the pointer is coarse, which is the whole reason this
  // exists: on a phone, tapping is how you scroll and select, and every one of
  // those taps used to summon the keyboard and cost a second tap to dismiss.
  // The KBD button is the deliberate way to ask for it. On a fine pointer there
  // is no soft keyboard to raise and focus-on-click is simply what a terminal
  // does, so nothing changes there.
  //
  // ?focus=1 / ?focus=0 override per client, and focusOnTap in ttyd's
  // preferences overrides for every client, the same shape as the toolbar
  // switch above.
  function focusOnTapWanted(search, coarsePointer, preference) {
    var params = new URLSearchParams(search || '');
    var value = params.get('focus');
    if (value === '1') return true;
    if (value === '0') return false;
    // "on"/"off" first, because that is dejima's own bool spelling and what
    // ttyd_focus_on_tap actually sends. The others are accepted because a
    // preference can also arrive from anything that writes ttyd -t directly.
    if (preference === 'on' || preference === true || preference === 'true' ||
        preference === '1') return true;
    if (preference === 'off' || preference === false || preference === 'false' ||
        preference === '0') return false;
    return !coarsePointer;
  }

  // Whether the toolbar is colour-coded by what each button is for.
  //
  // On unless the operator says otherwise: the hierarchy is the point of it,
  // and a toolbar where every key looks the same is one where the key you
  // need most is found by counting positions. "off" restores exactly the grey
  // it had before, for a terminal colour scheme this clashes with or an
  // operator who would rather it were quiet.
  function buttonColorsWanted(preference) {
    if (preference === 'off' || preference === false || preference === 'false' ||
        preference === '0') return false;
    return true;
  }

  // Rows of finger travel per scroll notch, from the preferences.
  //
  // ?scroll=N overrides per client, which matters more here than for the other
  // knobs: what a notch is worth depends on the application in the session,
  // and one operator can be looking at a tmux scrollback in one tab and a
  // full-screen app in another.
  //
  // Anything that is not a positive number falls back to the default rather
  // than being honoured. A zero or negative step would make the accumulator
  // loop that consumes it spin forever on the first drag, so this is a guard
  // rather than tidiness.
  function scrollStepRows(search, preference) {
    var params = new URLSearchParams(search || '');
    var candidates = [params.get('scroll'), preference];
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i] === null || candidates[i] === undefined ||
          candidates[i] === '') continue;
      var n = Number(candidates[i]);
      if (isFinite(n) && n > 0) return n;
    }
    return DEFAULT_SCROLL_STEP;
  }

  // The address of the session picker: this page with the run-id dropped.
  //
  // ttyd passes ?arg=<run-id> to dejima-attach as argv (--url-arg), so a page
  // loaded without it runs dejima-attach with no argument, which is the picker.
  // Every other parameter is kept, because they configure this page rather than
  // the command - losing ?toolbar=1 on the way back would be a surprise.
  //
  // Returns a search string, "" when nothing is left, so a caller can build a
  // URL without knowing whether to write the "?".
  function pickerSearch(search) {
    var params = new URLSearchParams(search || '');
    params.delete('arg');
    var rest = params.toString();
    return rest ? '?' + rest : '';
  }

  D.config = {
    DEFAULT_TMUX_PREFIX: DEFAULT_TMUX_PREFIX,
    DEFAULT_SCROLL_STEP: DEFAULT_SCROLL_STEP,
    PAGE_KEYS: PAGE_KEYS,
    parsePrefix: parsePrefix,
    splitPreferences: splitPreferences,
    toolbarWanted: toolbarWanted,
    focusOnTapWanted: focusOnTapWanted,
    buttonColorsWanted: buttonColorsWanted,
    scrollStepRows: scrollStepRows,
    pickerSearch: pickerSearch
  };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
