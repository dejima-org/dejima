// Wiring. Everything above this file is a layer that can be reasoned about on
// its own; this is where they are joined to a real Terminal and a real socket.
(function (D) {
  'use strict';

  var app = document.getElementById('app');
  var terminalHost = document.getElementById('terminal');
  var toolbarRoot = document.getElementById('toolbar');
  var toastEl = document.getElementById('toast');

  var toastTimer = null;
  function notify(message, sticky) {
    toastEl.textContent = message;
    toastEl.hidden = false;
    if (toastTimer !== null) clearTimeout(toastTimer);
    toastTimer = sticky ? null : setTimeout(clearNotice, 6000);
  }
  function clearNotice() {
    if (toastTimer !== null) clearTimeout(toastTimer);
    toastTimer = null;
    toastEl.hidden = true;
  }

  var term = new Terminal({
    cursorBlink: true,
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, "DejaVu Sans Mono", monospace',
    // tmux keeps its own history; this is only for output that never reached
    // an alternate screen.
    scrollback: 5000
  });
  var fitAddon = new FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  term.open(terminalHost);

  var mouse = D.mouse.createMouseEngine(term, function (sequence) {
    client.sendBinary(sequence);
  });
  var latch = D.keys.createCtrlLatch();
  var prefixByte = D.config.parsePrefix(D.config.DEFAULT_TMUX_PREFIX);
  var toolbar = null;

  function copyToClipboard(text) {
    if (!navigator.clipboard || !navigator.clipboard.writeText) {
      notify('Copying needs an https:// page; this one is not one.');
      return;
    }
    navigator.clipboard.writeText(text).catch(function () {
      notify('The browser refused to write to the clipboard.');
    });
  }

  function fitNow() {
    try {
      fitAddon.fit();
    } catch (e) {
      // Fitting a terminal that is momentarily zero-sized (mid rotation, or
      // before the first paint) is not an error worth surfacing.
    }
    if (client.isOpen()) client.sendResize(term.cols, term.rows);
  }

  var viewport = D.viewport.createViewport({ app: app, onFit: fitNow });

  // Whether this is a touch device, which decides both the toolbar below and
  // the keyboard policy that follows. Probed here rather than beside its first
  // use because applyPreferences needs it, and that runs on a message from
  // ttyd - later in wall-clock time, but easier to reason about declared
  // before the function that reads it.
  var coarsePointer = !!(window.matchMedia && window.matchMedia('(pointer: coarse)').matches);

  // Whether a tap may raise the soft keyboard.
  //
  // xterm.js focuses its textarea whenever the terminal is clicked, which on a
  // desktop is exactly right and on a phone is not: tapping is how you scroll
  // and select, so every one of those taps summoned the keyboard and cost a
  // second tap to put it away. The keyboard is now asked for explicitly, with
  // the KBD button.
  //
  // Implemented by blurring rather than by intercepting the tap. The focus
  // arrives from inside xterm.js on several paths - pointer, selection,
  // programmatic - and catching them all would mean knowing about each; letting
  // focus land and immediately dropping it needs to know about none, and leaves
  // selection and scrolling working exactly as they did. The toolbar does not
  // go through the textarea at all, so its keys keep working while the keyboard
  // is down.
  //
  // The flag resets on blur, so dismissing the keyboard by hand puts things
  // back to tap-does-not-raise-it rather than latching open.
  var keyboardAllowed = true;
  function allowKeyboard() { keyboardAllowed = true; }
  function applyTapFocusPolicy(wanted) {
    keyboardAllowed = wanted;
    if (wanted || !term.textarea) return;
    term.textarea.addEventListener('focus', function () {
      if (!keyboardAllowed && term.textarea) term.textarea.blur();
    });
    term.textarea.addEventListener('blur', function () { keyboardAllowed = false; });
  }

  function applyPreferences(prefs) {
    var split = D.config.splitPreferences(prefs);
    Object.keys(split.terminal).forEach(function (key) {
      try {
        term.options[key] = split.terminal[key];
      } catch (e) {
        // An option this build of xterm.js does not have. ttyd passes -t
        // options through verbatim, so this is the operator's typo, not a
        // reason to abandon the rest of the preferences.
      }
    });

    var spec = split.page.tmuxPrefix || D.config.DEFAULT_TMUX_PREFIX;
    var parsed = D.config.parsePrefix(spec);
    if (parsed === null) {
      notify('Could not read the configured tmux prefix "' + spec + '" - using C-b.');
      parsed = D.config.parsePrefix(D.config.DEFAULT_TMUX_PREFIX);
    }
    prefixByte = parsed;

    // Applied from the preferences as well as at startup: ttyd sends these
    // after the connection opens, so a focusOnTap set server-side arrives
    // later than the first policy decision and has to be able to change it.
    applyTapFocusPolicy(D.config.focusOnTapWanted(
      window.location.search, coarsePointer, split.page.focusOnTap));

    // A font size arriving in the preferences changes the cell size, so the
    // column count computed before it was applied is now wrong.
    viewport.refresh();
  }

  var client = D.protocol.createClient({
    location: window.location,
    size: function () { return { cols: term.cols, rows: term.rows }; },
    onOutput: function (bytes) { term.write(bytes); },
    onTitle: function (title) { document.title = title; },
    onPreferences: applyPreferences,
    onStatus: function (status) {
      if (status === 'open') {
        clearNotice();
        term.focus();
      } else if (status === 'closed') {
        notify('Disconnected. Reconnecting...', true);
      }
    }
  });

  // Sticky Ctrl is applied here rather than in attachCustomKeyEventHandler
  // because the target is a phone: soft keyboards overwhelmingly report
  // keydown as "Unidentified" and deliver the real character through an input
  // event instead, so a keydown-based transform would work on a desktop and
  // silently do nothing where it is actually needed. onData is downstream of
  // both paths. Sequences (arrows, Enter, Backspace) have no control code and
  // fall through untouched.
  term.onData(function (data) {
    if (latch.armed() && data.length > 0) {
      var sequence = D.keys.ctrlSequence(data.charAt(0));
      if (sequence !== null) {
        latch.consume();
        if (toolbar) toolbar.refreshLatches();
        client.sendInput(sequence + data.slice(1));
        return;
      }
    }
    client.sendInput(data);
  });
  term.onBinary(function (data) { client.sendBinary(data); });

  // OSC 52 is how a terminal application says "put this on the clipboard" -
  // tmux with set-clipboard, nvim, or anything else that emits it. xterm.js
  // has no handler of its own, so without this a yank goes nowhere.
  //
  // Announced every time, because the writer is whatever is running in the
  // session and not necessarily you: a clipboard that changes silently is one
  // you paste from believing you know what is on it. The toast is the only
  // thing standing between "a session wrote your clipboard" and your next
  // PASTE, so it is not conditional on the payload looking suspicious.
  term.parser.registerOscHandler(52, function (data) {
    var text = D.osc52.decodeOsc52(data);
    if (text !== null) {
      copyToClipboard(text);
      notify('The session put ' + text.length + ' characters on your clipboard.');
    } else if (D.osc52.oversize(data)) {
      notify('The session tried to put more than ' +
        Math.floor(D.osc52.MAX_CLIPBOARD_BYTES / 1024) +
        'KB on your clipboard. Ignored.');
    }
    return true;
  });

  // Touch affordances only where there is a touch. A desktop browser gets a
  // plain terminal, which is what lets this ship as the default frontend.
  if (D.config.toolbarWanted(window.location.search, coarsePointer)) {
    document.body.classList.add('touch');
    toolbar = D.toolbar.createToolbar({
      root: toolbarRoot,
      term: term,
      modes: mouse.modes,
      latch: latch,
      // sendInput, not sendBinary: a paste can contain any character, and
      // sendBinary truncates to a byte. Every sequence these buttons send is
      // ASCII, which UTF-8 leaves alone.
      sendText: function (text) { client.sendInput(text); },
      prefix: function () { return prefixByte; },
      notify: notify,
      search: function () { return window.location.search; },
      navigate: function (search) { window.location.search = search; },
      allowKeyboard: allowKeyboard
    });
    toolbar.attach();

    D.gestures.createGestures({
      element: terminalHost,
      term: term,
      mouse: mouse,
      dragMode: toolbar.dragMode,
      onCopy: copyToClipboard
    }).attach();
  }

  viewport.attach();
  client.connect();
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
