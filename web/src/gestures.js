// Gesture recognition: tap, one-finger drag, two-finger drag, long-press.
//
// The rule that shapes all of it is that a stationary tap must be left
// entirely alone. Browsers synthesise a mouse click from a touch that neither
// moved nor had its touchmove defaulted, and that synthetic click is what
// already makes tapping work in xterm - selecting a tmux window from the
// status bar, positioning a cursor. So preventDefault() is called only once a
// gesture has actually been claimed, never on touchstart.
(function (D) {
  'use strict';

  var LONG_PRESS_MS = 400;
  // Far enough that resting a thumb is not a drag, near enough that a
  // deliberate one is claimed before it feels stuck.
  var MOVE_THRESHOLD_PX = 10;

  function distance(a, b) {
    return Math.sqrt(Math.pow(a.x - b.x, 2) + Math.pow(a.y - b.y, 2));
  }

  function pointOf(touch) {
    return { x: touch.clientX, y: touch.clientY };
  }

  function buzz(ms) {
    if (navigator.vibrate) navigator.vibrate(ms);
  }

  // opts: {element, term, mouse, dragMode() -> bool, scrollStep() -> rows,
  //        onCopy(text)}
  function createGestures(opts) {
    var term = opts.term;
    var mouse = opts.mouse;

    var mode = null; // null | 'scroll' | 'drag' | 'select'
    var start = null;
    var current = null;
    var lastCell = null;
    var scrollAccum = 0;
    var longPressTimer = null;

    function cancelLongPress() {
      if (longPressTimer !== null) {
        clearTimeout(longPressTimer);
        longPressTimer = null;
      }
    }

    // Selection has to be driven through xterm's own selection service rather
    // than by tracking cells here, so that what the user sees highlighted and
    // what getSelection() returns are the same thing. While an application
    // holds the mouse, xterm hands it every event and suppresses selection -
    // unless Shift is held, which is exactly the escape hatch a desktop user
    // has. So these carry shiftKey.
    function synthesiseMouse(type, point) {
      var target = mouse.screenElement();
      if (!target) return;
      target.dispatchEvent(new MouseEvent(type, {
        bubbles: true,
        cancelable: true,
        view: window,
        clientX: point.x,
        clientY: point.y,
        button: 0,
        buttons: type === 'mouseup' ? 0 : 1,
        shiftKey: true,
        detail: 1
      }));
    }

    function beginSelection() {
      longPressTimer = null;
      if (mode !== null || start === null) return;
      mode = 'select';
      buzz(10);
      term.clearSelection();
      synthesiseMouse('mousedown', start);
    }

    function endSelection() {
      synthesiseMouse('mouseup', current || start);
      var text = term.getSelection();
      if (text) opts.onCopy(text);
    }

    // Dragging down pulls earlier output into view, and how far the finger
    // travels per notch depends on who is receiving the notch.
    //
    // This page scrolling its own scrollback moves one row per notch, so one
    // row of travel per notch tracks the finger exactly. An application
    // receiving the wheel does not: stock tmux scrolls five rows for one, and
    // a full-screen app picks its own figure. A notch per row there moved the
    // screen several times faster than the finger, which is what made placing
    // a line at the bottom of the screen a matter of several tries.
    //
    // So the travel is multiplied only on the path where a notch is worth
    // more than a row. Applying it to both would make the scrollback
    // sluggish to fix something that is not wrong there.
    function scrollBy(dy, point) {
      scrollAccum += dy;
      var step = mouse.cellHeight();
      if (mouse.enabled()) step *= opts.scrollStep();
      if (step <= 0) return;
      while (Math.abs(scrollAccum) >= step) {
        var up = scrollAccum > 0;
        scrollAccum += up ? -step : step;
        if (mouse.enabled()) {
          var cell = mouse.cellAt(point.x, point.y);
          if (cell) mouse.wheel(cell, up);
        } else {
          term.scrollLines(up ? -1 : 1);
        }
      }
    }

    function onTouchStart(event) {
      if (mode === null && event.touches.length === 1) {
        start = pointOf(event.touches[0]);
        current = start;
        lastCell = null;
        scrollAccum = 0;
        cancelLongPress();
        longPressTimer = setTimeout(beginSelection, LONG_PRESS_MS);
        return;
      }
      // A second finger is never a long press, and never a drag: two-finger
      // scrolling is the one gesture that works in both drag modes, so a
      // forgotten DRAG toggle can't strand anyone without a way to scroll.
      cancelLongPress();
      if (mode === null && event.touches.length > 1) {
        start = pointOf(event.touches[0]);
        scrollAccum = 0;
        mode = 'scroll';
      }
    }

    function onTouchMove(event) {
      if (start === null || event.touches.length === 0) return;
      var point = pointOf(event.touches[0]);
      current = point;

      if (mode === null) {
        if (distance(point, start) < MOVE_THRESHOLD_PX) return;
        cancelLongPress();
        // A drag is forwarded to the application only when the user has asked
        // for it AND something is listening. Automatic would mean a finger
        // drag inside vim starts selecting text the moment the user meant to
        // scroll, which is why DRAG is an explicit toggle.
        if (opts.dragMode() && mouse.enabled()) {
          mode = 'drag';
          lastCell = mouse.cellAt(start.x, start.y);
          if (lastCell) mouse.press(lastCell);
        } else {
          mode = 'scroll';
        }
      }

      // From here the gesture is ours, so the browser must not also scroll the
      // page or start its own selection.
      event.preventDefault();

      if (mode === 'select') {
        synthesiseMouse('mousemove', point);
        return;
      }
      if (mode === 'drag') {
        var cell = mouse.cellAt(point.x, point.y);
        if (cell && (!lastCell || cell.col !== lastCell.col || cell.row !== lastCell.row)) {
          lastCell = cell;
          mouse.motion(cell);
        }
        return;
      }
      scrollBy(point.y - start.y, point);
      start = point;
    }

    function onTouchEnd(event) {
      cancelLongPress();
      // A finger lifting while others remain is not the end of the gesture -
      // finishing here would release a drag or copy a selection mid-way. Only
      // re-anchor, because the finger that is left is somewhere the gesture
      // was never measured from, and the next move would read as a jump.
      if (event.touches.length > 0) {
        start = pointOf(event.touches[0]);
        current = start;
        scrollAccum = 0;
        return;
      }
      if (mode === 'select') {
        endSelection();
        event.preventDefault();
      } else if (mode === 'drag') {
        if (lastCell) mouse.release(lastCell);
        event.preventDefault();
      }
      mode = null;
      start = null;
      current = null;
      lastCell = null;
      scrollAccum = 0;
    }

    function attach() {
      var el = opts.element;
      el.addEventListener('touchstart', onTouchStart, { passive: false });
      el.addEventListener('touchmove', onTouchMove, { passive: false });
      el.addEventListener('touchend', onTouchEnd, { passive: false });
      el.addEventListener('touchcancel', onTouchEnd, { passive: false });
    }

    return { attach: attach, LONG_PRESS_MS: LONG_PRESS_MS };
  }

  D.gestures = { createGestures: createGestures, MOVE_THRESHOLD_PX: MOVE_THRESHOLD_PX };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
