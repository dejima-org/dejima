'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
require('../src/keys.js');
const { ctrlSequence, createCtrlLatch } = globalThis.DEJIMA.keys;

test('letters map to their control code, in either case', () => {
  assert.equal(ctrlSequence('a'), '\x01');
  assert.equal(ctrlSequence('A'), '\x01');
  assert.equal(ctrlSequence('c'), '\x03');
  assert.equal(ctrlSequence('z'), '\x1a');
});

test('the non-alphabetic control codes are covered too', () => {
  assert.equal(ctrlSequence('@'), '\x00');
  assert.equal(ctrlSequence(' '), '\x00');
  assert.equal(ctrlSequence('Space'), '\x00');
  assert.equal(ctrlSequence('['), '\x1b');
  assert.equal(ctrlSequence('\\'), '\x1c');
  assert.equal(ctrlSequence(']'), '\x1d');
  assert.equal(ctrlSequence('^'), '\x1e');
  assert.equal(ctrlSequence('_'), '\x1f');
  assert.equal(ctrlSequence('?'), '\x7f');
});

test('keys with no control code are left alone', () => {
  for (const key of ['ArrowUp', 'Enter', 'Tab', 'F5', 'é', '1', '', null, undefined]) {
    assert.equal(ctrlSequence(key), null, `${key} should have no control code`);
  }
});

test('one tap arms Ctrl for a single key, which then consumes it', () => {
  const latch = createCtrlLatch();
  assert.equal(latch.state(), 'off');
  assert.equal(latch.armed(), false);

  assert.equal(latch.tap(), 'once');
  assert.equal(latch.armed(), true);
  latch.consume();
  assert.equal(latch.state(), 'off');
  assert.equal(latch.armed(), false);
});

test('a second tap locks Ctrl on until a third taps it off', () => {
  const latch = createCtrlLatch();
  latch.tap();
  assert.equal(latch.tap(), 'locked');
  latch.consume();
  assert.equal(latch.state(), 'locked', 'a locked latch survives being used');
  latch.consume();
  assert.equal(latch.armed(), true);
  assert.equal(latch.tap(), 'off');
  assert.equal(latch.armed(), false);
});
