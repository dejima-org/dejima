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
function makeWorld(scrollStep, reporting) {
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
    scrollStep: () => scrollStep,
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

// The page scrolling its own scrollback moves one row per notch, so one row of
// travel per notch already tracks the finger exactly. Nothing here should
// change that.

test('scrollback moves one row per row of finger travel, whatever the step', () => {
  for (const step of [1, 5, 40]) {
    const w = makeWorld(step, false);
    w.dragDown(10);
    assert.equal(w.scrolled.length, 10, 'step ' + step + ' reached the scrollback');
    assert.ok(w.scrolled.every((n) => n === -1), 'dragging down goes back in history');
    assert.equal(w.wheeled.length, 0, 'no application is listening');
  }
});

// An application receiving the wheel scrolls several rows for one notch -
// stock tmux binds copy-mode's WheelUpPane to `send -X -N 5 scroll-up` - so
// this is the path where a notch per row outran the finger.

test('an application gets one notch per scroll_step rows of travel', () => {
  const w = makeWorld(5, true);
  w.dragDown(10);
  assert.equal(w.wheeled.length, 2, '10 rows of travel at 5 rows a notch');
  assert.ok(w.wheeled.every((d) => d === 'up'), 'dragging down scrolls up');
  assert.equal(w.scrolled.length, 0, 'the page did not also scroll itself');
});

test('a step of one is the old behaviour, still reachable', () => {
  const w = makeWorld(1, true);
  w.dragDown(10);
  assert.equal(w.wheeled.length, 10);
});

test('travel shorter than one step sends nothing rather than rounding up', () => {
  // The point of the setting: a small movement of the finger should not move
  // the screen at all, rather than moving it several rows.
  const w = makeWorld(5, true);
  w.dragDown(4);
  assert.equal(w.wheeled.length, 0);
});

test('dragging up scrolls forward again', () => {
  const w = makeWorld(5, true);
  w.element.fire('touchstart', touchEvent([{ x: 100, y: 300 }]));
  w.element.fire('touchmove', touchEvent([{ x: 100, y: 300 - 10 * CELL }]));
  assert.deepEqual(w.wheeled, ['down', 'down']);
});
