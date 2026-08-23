// The toolbar: keys a phone keyboard does not have, and the two tmux windows
// buttons that replace a status-bar entry a few pixels wide.
//
// Every handler binds pointerdown and calls preventDefault(). That is the
// whole reason tapping a button neither moves focus nor dismisses the soft
// keyboard - the default action of a pointerdown on a button is to focus it,
// which blurs the terminal's textarea and takes the keyboard down with it.
// Requires config.js, for the picker address the SESS button navigates to.

(function (D) {
  'use strict';

  function buzz(ms) {
    if (navigator.vibrate) navigator.vibrate(ms);
  }

  // What PASTE actually sends, and whether the operator needs telling.
  //
  // Bracketed paste tells the application this is pasted text rather than
  // typing, which stops an editor auto-indenting every line into a staircase
  // and, more to the point, means the application sees the text as data so
  // nothing runs on arrival.
  //
  // Without it - a plain shell, one tmux prefix key away - the application
  // cannot tell a paste from typing, so a trailing newline is
  // indistinguishable from pressing Enter and the last line runs on arrival.
  // The clipboard is session-writable through OSC 52, which makes that a path
  // from "the session put text there" to "a shell ran it" with no keystroke
  // of yours in between. The trailing newlines are stripped rather than the
  // paste refused: it still lands, you press Enter yourself.
  //
  // Line breaks left in the MIDDLE still arrive as Enter. That is true of
  // pasting into any terminal without bracketed paste and is not something
  // this can fix without refusing legitimate pastes, so it is said out loud
  // instead of silently trusted - the content may not be yours.
  function pasteSequence(text, bracketed) {
    if (bracketed) return { send: '\x1b[200~' + text + '\x1b[201~', warn: false };
    var stripped = text.replace(/[\r\n]+$/, '');
    return { send: stripped, warn: /[\r\n]/.test(stripped) };
  }

  // opts: {root, term, modes, latch, sendText(text), prefix() -> string|null,
  //        notify(message)}
  function createToolbar(opts) {
    var dragMode = false;

    // Cursor keys have two forms and the application chooses: DECCKM switches
    // them to SS3. These buttons are the only arrow keys a phone has, so they
    // have to make the same choice a real keyboard would.
    function cursorKey(letter) {
      return (opts.modes.applicationCursor() ? '\x1bO' : '\x1b[') + letter;
    }

    function sendPrefix(suffix) {
      var prefix = opts.prefix();
      if (!prefix) {
        opts.notify('No tmux prefix is configured, so this button has nothing to send.');
        return;
      }
      opts.sendText(prefix + (suffix || ''));
    }

    function paste() {
      // Undefined outside a secure context, which is a deployment mistake
      // worth naming rather than a button that does nothing.
      if (!navigator.clipboard || !navigator.clipboard.readText) {
        opts.notify('Reading the clipboard needs an https:// page; this one is not one.');
        return;
      }
      navigator.clipboard.readText().then(function (text) {
        if (!text) return;
        var paste = pasteSequence(text, opts.modes.bracketedPaste());
        if (paste.warn) {
          opts.notify('Pasted text with line breaks into an application that does not support bracketed paste - each break arrives as Enter.');
        }
        opts.sendText(paste.send);
      }).catch(function () {
        opts.notify('The browser refused the clipboard. Allow clipboard access for this site, then tap PASTE again.');
      });
    }

    function refreshLatches() {
      var ctrl = opts.root.querySelector('[data-action="ctrl"]');
      if (ctrl) {
        ctrl.classList.toggle('is-armed', opts.latch.state() === 'once');
        ctrl.classList.toggle('is-locked', opts.latch.state() === 'locked');
      }
      var drag = opts.root.querySelector('[data-action="drag"]');
      if (drag) drag.classList.toggle('is-locked', dragMode);
    }

    var ACTIONS = {
      esc: function () { opts.sendText('\x1b'); },
      tab: function () { opts.sendText('\t'); },
      up: function () { opts.sendText(cursorKey('A')); },
      down: function () { opts.sendText(cursorKey('B')); },
      right: function () { opts.sendText(cursorKey('C')); },
      left: function () { opts.sendText(cursorKey('D')); },
      ctrl: function () { opts.latch.tap(); refreshLatches(); },
      prefix: function () { sendPrefix(''); },
      'prev-window': function () { sendPrefix('p'); },
      'next-window': function () { sendPrefix('n'); },
      zoom: function () { sendPrefix('z'); },
      drag: function () {
        dragMode = !dragMode;
        // A mode change nobody can see is a mode change nobody remembers
        // making; the buzz is what makes it perceptible without looking.
        buzz(10);
        refreshLatches();
      },
      paste: paste,
      // Carriage return, not a newline. A terminal's Enter key is CR; sending
      // LF here would submit nothing in a shell and insert a line in an editor.
      enter: function () { opts.sendText('\r'); },
      // Back to dejima-attach with no run-id, which is the picker. A full
      // navigation rather than anything cleverer: the run-id reaches the
      // command through ttyd's --url-arg on the WebSocket URL, so the only way
      // to run a different one is a new connection.
      //
      // Safe for the session being left. dejima-attach gives each client its
      // own tmux session grouped onto the real one and sets destroy-unattached
      // on THAT, so detaching reaps the view and leaves the sandbox pane alone.
      sessions: function () {
        if (opts.navigate) opts.navigate(D.config.pickerSearch(opts.search()));
      },
      kbd: function () {
        opts.term.focus();
        if (opts.term.textarea) opts.term.textarea.focus();
      }
    };

    function onPointerDown(event) {
      var button = event.target.closest('[data-action]');
      if (!button) return;
      var action = ACTIONS[button.dataset.action];
      if (!action) return;
      // Before the action, not after: the terminal must not lose focus even if
      // the action itself throws.
      event.preventDefault();
      action();
    }

    function attach() {
      opts.root.addEventListener('pointerdown', onPointerDown);
      opts.root.hidden = false;
      refreshLatches();
    }

    return {
      attach: attach,
      dragMode: function () { return dragMode; },
      refreshLatches: refreshLatches
    };
  }

  D.toolbar = { createToolbar: createToolbar, pasteSequence: pasteSequence };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
