'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
require('../src/keyboard.js');
const { createKeyboardPolicy, KEYBOARD_MIN_PX } = globalThis.DEJIMA.keyboard;

// An element that records focus the way the DOM does, including the part that
// caused the bug: focusing something already focused fires no focus event.
function makeElement() {
  const listeners = {};
  return {
    focused: false,
    listeners: listeners,
    addEventListener: (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); },
    fire: function (type) { (listeners[type] || []).forEach((fn) => fn()); },
    focus: function () {
      if (this.focused) return;
      this.focused = true;
      this.fire('focus');
    },
    blur: function () {
      if (!this.focused) return;
      this.focused = false;
      this.fire('blur');
    }
  };
}

// term, terminal element and visual viewport, plus a defer() that runs on
// demand so a test can see the state between the tap and the blur.
function makeWorld(layoutHeight) {
  const textarea = makeElement();
  const element = makeElement();
  const visualViewport = makeElement();
  visualViewport.height = layoutHeight || 800;
  const deferred = [];
  const policy = createKeyboardPolicy({
    term: { textarea: textarea },
    element: element,
    visualViewport: visualViewport,
    layoutHeight: () => layoutHeight || 800,
    defer: (fn) => deferred.push(fn)
  });
  policy.attach();
  return {
    policy, textarea, element, visualViewport,
    tap: function () {
      element.fire('pointerdown');
      // xterm focuses the textarea from its own handler, synchronously, before
      // anything deferred runs.
      textarea.focus();
      while (deferred.length) deferred.shift()();
    },
    keyboardTo: function (up) {
      visualViewport.height = up ? (layoutHeight || 800) - KEYBOARD_MIN_PX - 1 : (layoutHeight || 800);
      visualViewport.fire('resize');
    }
  };
}

test('with no policy set, a tap focuses the terminal as it always has', () => {
  // The desktop path, and the one that ships if setRaiseOnTap is never called.
  const w = makeWorld();
  w.tap();
  assert.equal(w.textarea.focused, true);
});

test('a tap does not leave the terminal focused when taps must not raise the keyboard', () => {
  const w = makeWorld();
  w.policy.setRaiseOnTap(false);
  w.tap();
  assert.equal(w.textarea.focused, false);
});

test('a tap on an ALREADY focused terminal still drops the focus', () => {
  // The reported bug. Focusing a focused element fires no focus event, so a
  // focus handler alone never runs - and the terminal is focused as a matter
  // of course, because the page focuses it when the connection opens.
  const w = makeWorld();
  w.textarea.focus();
  w.policy.setRaiseOnTap(false);
  assert.equal(w.textarea.focused, false, 'the standing focus is dropped when the policy lands');

  w.textarea.focused = true; // as if the system had put it back without an event
  w.tap();
  assert.equal(w.textarea.focused, false);
});

test('KBD is what raises the keyboard, and it survives a tap afterwards', () => {
  const w = makeWorld();
  w.policy.setRaiseOnTap(false);
  w.policy.allow();
  w.textarea.focus();
  assert.equal(w.textarea.focused, true, 'the deliberate request is honoured');

  // Having asked for the keyboard, tapping to move the cursor must not take it
  // away again.
  w.tap();
  assert.equal(w.textarea.focused, true);
});

test('dismissing the keyboard re-locks it, so the next tap does not bring it back', () => {
  const w = makeWorld();
  w.policy.setRaiseOnTap(false);
  w.policy.allow();
  w.textarea.focus();
  w.textarea.blur();
  w.tap();
  assert.equal(w.textarea.focused, false);
});

test('a keyboard closed by a system gesture re-locks, though it fires no blur', () => {
  // Android's back gesture closes the keyboard and leaves the element focused.
  // Without the viewport watching, one KBD would unlock taps permanently.
  const w = makeWorld();
  w.policy.setRaiseOnTap(false);
  w.policy.allow();
  w.textarea.focus();
  w.keyboardTo(true);
  w.keyboardTo(false);
  assert.equal(w.textarea.focused, false, 'focus is dropped when the keyboard goes');

  w.textarea.focused = true;
  w.tap();
  assert.equal(w.textarea.focused, false);
});

test('the viewport is left alone where taps are meant to raise the keyboard', () => {
  // A desktop window shrinking, or a phone with focus_on_tap = on. Nothing
  // here should be stealing focus from a terminal that is meant to have it.
  const w = makeWorld();
  w.policy.setRaiseOnTap(true);
  w.textarea.focus();
  w.keyboardTo(true);
  w.keyboardTo(false);
  assert.equal(w.textarea.focused, true);
});

test('setting the policy again does not stack up listeners', () => {
  // Preferences arrive on every reconnect, so this runs more than once.
  const w = makeWorld();
  w.policy.setRaiseOnTap(false);
  w.policy.setRaiseOnTap(false);
  w.policy.setRaiseOnTap(true);
  assert.equal(w.textarea.listeners.focus.length, 1);
  assert.equal(w.textarea.listeners.blur.length, 1);
  assert.equal(w.element.listeners.pointerdown.length, 1);
});

test('raisesOnTap reports the policy, so the page knows whether to focus on connect', () => {
  const w = makeWorld();
  assert.equal(w.policy.raisesOnTap(), true);
  w.policy.setRaiseOnTap(false);
  assert.equal(w.policy.raisesOnTap(), false);
});

test('a terminal with no textarea yet is not a crash', () => {
  // term.textarea is null until the terminal is opened.
  const policy = createKeyboardPolicy({ term: {}, element: makeElement() });
  policy.attach();
  policy.setRaiseOnTap(false);
  policy.allow();
});
