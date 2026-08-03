'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
require('../src/modes.js');
const { createModeTracker } = globalThis.DEJIMA.modes;

test('the CSI handlers always return false so xterm still sees the sequence', () => {
  const t = createModeTracker();
  assert.equal(t.set([1000]), false);
  assert.equal(t.reset([1000]), false);
  assert.equal(t.set([25]), false);
  assert.equal(t.reset([]), false);
});

test('1000, 1002 and 1003 each mean the application wants the mouse', () => {
  for (const mode of [1000, 1002, 1003]) {
    const t = createModeTracker();
    assert.equal(t.mouseReporting(), false);
    t.set([mode]);
    assert.equal(t.mouseReporting(), true, `mode ${mode} should enable mouse reporting`);
    t.reset([mode]);
    assert.equal(t.mouseReporting(), false, `mode ${mode} should be resettable`);
  }
});

test('only 1002 and 1003 ask for motion reports', () => {
  const t = createModeTracker();
  t.set([1000]);
  assert.equal(t.motionReporting(), false);
  t.set([1002]);
  assert.equal(t.motionReporting(), true);
  t.reset([1002]);
  assert.equal(t.motionReporting(), false);
  t.set([1003]);
  assert.equal(t.motionReporting(), true);
});

test('1006 selects SGR encoding and 2004 bracketed paste', () => {
  const t = createModeTracker();
  assert.equal(t.sgrEncoding(), false);
  assert.equal(t.bracketedPaste(), false);
  t.set([1006, 2004]);
  assert.equal(t.sgrEncoding(), true);
  assert.equal(t.bracketedPaste(), true);
  t.reset([1006]);
  assert.equal(t.sgrEncoding(), false);
  assert.equal(t.bracketedPaste(), true);
});

test('DECCKM decides which form the arrow buttons send', () => {
  const t = createModeTracker();
  assert.equal(t.applicationCursor(), false);
  t.set([1]);
  assert.equal(t.applicationCursor(), true);
  assert.equal(t.mouseReporting(), false, 'mode 1 is not a mouse mode');
  t.reset([1]);
  assert.equal(t.applicationCursor(), false);
});

test('untracked modes change nothing', () => {
  const t = createModeTracker();
  t.set([25, 1049, 12]);
  assert.equal(t.applicationCursor(), false);
  assert.equal(t.mouseReporting(), false);
  assert.equal(t.sgrEncoding(), false);
  assert.equal(t.bracketedPaste(), false);
});

test('a parameter arriving as a sub-parameter array uses its first value', () => {
  const t = createModeTracker();
  t.set([[1002], 1006]);
  assert.equal(t.motionReporting(), true);
  assert.equal(t.sgrEncoding(), true);
});

test('reset() clears every tracked mode, as a terminal reset would', () => {
  const t = createModeTracker();
  t.set([1, 1000, 1002, 1006, 2004]);
  t.clear();
  assert.equal(t.applicationCursor(), false);
  assert.equal(t.mouseReporting(), false);
  assert.equal(t.motionReporting(), false);
  assert.equal(t.sgrEncoding(), false);
  assert.equal(t.bracketedPaste(), false);
});
