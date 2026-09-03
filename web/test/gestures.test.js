'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
require('../src/gestures.js');
const { createGestures } = globalThis.DEJIMA.gestures;

const CELL = 20; // rows are 20px tall in every world below

// An element that records the listeners createGestures attaches, so a test can
// fire a touch sequence at it without a DOM.
function makeElement() {
  const listeners = {};
  return {
    addEventListener: (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); },
    fire: (type, event) => { (listeners[type] || []).forEach((fn) => fn(event)); }
  };
}

function touchEvent(points) {
  return {
    touches: points.map((p) => ({ clientX: p.x, clientY: p.y })),
    preventDefault: function () { this.defaultPrevented = true; },
    defaultPrevented: false
  };
}

// reporting: whether the application has asked for mouse reports, which is
// what decides who receives a notch and so what one is worth.
function makeWorld(reporting) {
  const element = makeElement();
  const scrolled = [];   // this page's own scrollback, one row per entry
  const wheeled = [];    // notches sent to the application
  const gestures = createGestures({
    element: element,
    term: {
      scrollLines: (n) => scrolled.push(n),
      getSelection: () => ''
    },
    mouse: {
      cellHeight: () => CELL,
      enabled: () => !!reporting,
      cellAt: () => ({ col: 1, row: 1 }),
      wheel: (cell, up) => wheeled.push(up ? 'up' : 'down'),
      altScreen: () => false,
      press: () => {}, motion: () => {}, release: () => {}
    },
    dragMode: () => false,
    onCopy: () => {}
  });
  gestures.attach();
  return {
    element, scrolled, wheeled,
    // A one-finger drag of `rows` rows, downward, which pulls earlier output
    // into view. Delivered as one touchmove: scrollBy accumulates travel, so
    // the split into events is not what the count under test depends on.
    dragDown: function (rows) {
      element.fire('touchstart', touchEvent([{ x: 100, y: 100 }]));
      element.fire('touchmove', touchEvent([{ x: 100, y: 100 + rows * CELL }]));
      element.fire('touchend', touchEvent([]));
    }
  };
}

// One notch per row of finger travel, whichever side receives the notch.
// What a notch is then WORTH belongs to the receiver: this page moves one row,
// and tmux's copy mode moves five until its binding says otherwise.

test('scrollback moves one row per row of finger travel', () => {
  const w = makeWorld(false);
  w.dragDown(10);
  assert.equal(w.scrolled.length, 10);
  assert.ok(w.scrolled.every((n) => n === -1), 'dragging down goes back in history');
  assert.equal(w.wheeled.length, 0, 'no application is listening');
});

test('an application gets one notch per row of finger travel', () => {
  const w = makeWorld(true);
  w.dragDown(10);
  assert.equal(w.wheeled.length, 10);
  assert.ok(w.wheeled.every((d) => d === 'up'), 'dragging down scrolls up');
  assert.equal(w.scrolled.length, 0, 'the page did not also scroll itself');
});

test('travel shorter than a row sends nothing rather than rounding up', () => {
  const w = makeWorld(true);
  w.element.fire('touchstart', touchEvent([{ x: 100, y: 200 }]));
  w.element.fire('touchmove', touchEvent([{ x: 100, y: 200 + CELL / 2 }]));
  assert.equal(w.wheeled.length, 0);
});

test('dragging up scrolls forward again', () => {
  const w = makeWorld(true);
  w.element.fire('touchstart', touchEvent([{ x: 100, y: 300 }]));
  w.element.fire('touchmove', touchEvent([{ x: 100, y: 300 - 3 * CELL }]));
  assert.deepEqual(w.wheeled, ['down', 'down', 'down']);
});
