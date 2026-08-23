// Whether a tap on the terminal may raise the soft keyboard.
//
// xterm.js focuses its textarea whenever the terminal is clicked, which on a
// desktop is exactly right and on a phone is not: tapping is also how you
// scroll and select, so every one of those taps summons the keyboard and costs
// a second tap to put it away. The keyboard is asked for explicitly instead,
// with the toolbar's KBD button.
//
// Done by letting focus land and dropping it, rather than by intercepting the
// tap. Focus arrives from several paths inside xterm.js - pointer, selection,
// programmatic - and catching each would mean knowing about each. Selection and
// scrolling are untouched, and the toolbar's own keys never go through the
// textarea, so they keep working with the keyboard down.
(function (D) {
  'use strict';

  // How much of the screen something has to cover before it is a keyboard
  // rather than an address bar sliding into view.
  var KEYBOARD_MIN_PX = 120;

  // opts: {term, element, visualViewport, layoutHeight(), defer(fn)}
  function createKeyboardPolicy(opts) {
    // Both start permissive, so a page that never calls setRaiseOnTap behaves
    // exactly as a terminal always has.
    var raiseOnTap = true;
    var allowed = true;
    var keyboardWasUp = false;

    var defer = opts.defer || function (fn) { setTimeout(fn, 0); };
    var layoutHeight = opts.layoutHeight || function () { return window.innerHeight; };

    function textarea() { return opts.term.textarea || null; }

    // "The keyboard should stay down": taps do not raise it, and nobody has
    // asked for it since it last went away.
    function locked() { return !raiseOnTap && !allowed; }

    function dropFocus() {
      var el = textarea();
      if (el && locked()) el.blur();
    }

    // Focus alone is not enough to hang this on. Tapping a textarea that is
    // ALREADY the focused element raises the keyboard again and fires no focus
    // event, and there are two ordinary ways to arrive at a focused textarea
    // with the keyboard down: the terminal is focused when the connection
    // opens, and a keyboard dismissed by a system gesture leaves focus where it
    // was. Both were exactly the reported bug. So the tap is watched too, and
    // the blur deferred to let xterm's own focus call happen first.
    function onPointerDown() {
      if (locked()) defer(dropFocus);
    }

    // Dismissing the keyboard means the next tap should not bring it back, so
    // a blur re-locks. This is also how a dropped focus feeds back in.
    function onBlur() { allowed = false; }

    // A keyboard dismissed with the system's own gesture does not blur the
    // element it belongs to, so KBD would otherwise unlock things for good.
    // The visual viewport is the only thing that sees a keyboard at all: it is
    // covered by one rather than resized by it.
    function onViewportResize() {
      var vv = opts.visualViewport;
      if (!vv) return;
      var up = (layoutHeight() - vv.height) > KEYBOARD_MIN_PX;
      if (keyboardWasUp && !up && !raiseOnTap) {
        allowed = false;
        var el = textarea();
        if (el) el.blur();
      }
      keyboardWasUp = up;
    }

    // Listeners are attached once, and the policy they consult is a variable.
    // Re-attaching per policy change would stack duplicates, since preferences
    // arrive again on every reconnect.
    function attach() {
      var el = textarea();
      if (el) {
        el.addEventListener('focus', dropFocus);
        el.addEventListener('blur', onBlur);
      }
      if (opts.element) opts.element.addEventListener('pointerdown', onPointerDown);
      if (opts.visualViewport) opts.visualViewport.addEventListener('resize', onViewportResize);
    }

    // Called at startup with the pointer-type default and again when ttyd's
    // preferences arrive. Dropping focus here is what handles the terminal
    // being focused already, which it is by the time preferences land.
    function setRaiseOnTap(wanted) {
      raiseOnTap = !!wanted;
      allowed = raiseOnTap;
      if (!raiseOnTap) dropFocus();
    }

    return {
      attach: attach,
      setRaiseOnTap: setRaiseOnTap,
      raisesOnTap: function () { return raiseOnTap; },
      // The one deliberate request for the keyboard, so the one thing that
      // unlocks it.
      allow: function () { allowed = true; }
    };
  }

  D.keyboard = { createKeyboardPolicy: createKeyboardPolicy, KEYBOARD_MIN_PX: KEYBOARD_MIN_PX };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
