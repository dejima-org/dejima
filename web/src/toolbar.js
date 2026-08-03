// The toolbar: keys a phone keyboard does not have, and the two tmux windows
// buttons that replace a status-bar entry a few pixels wide.
//
// Every handler binds pointerdown and calls preventDefault(). That is the
// whole reason tapping a button neither moves focus nor dismisses the soft
// keyboard - the default action of a pointerdown on a button is to focus it,
// which blurs the terminal's textarea and takes the keyboard down with it.
(function (D) {
  'use strict';

  function buzz(ms) {
    if (navigator.vibrate) navigator.vibrate(ms);
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
        // Bracketed paste tells the application this is pasted text rather
        // than typing, which is what stops an editor auto-indenting every
        // line of it into a staircase.
        opts.sendText(
          opts.modes.bracketedPaste() ? '\x1b[200~' + text + '\x1b[201~' : text
        );
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

  D.toolbar = { createToolbar: createToolbar };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
