'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
require('../src/keys.js'); // config.js parses the tmux prefix through it
require('../src/config.js');
const { DEFAULT_TMUX_PREFIX, parsePrefix, splitPreferences, toolbarWanted,
        pickerSearch } = globalThis.DEJIMA.config;

test('a tmux prefix is parsed into the byte tmux would receive', () => {
  assert.equal(parsePrefix('C-b'), '\x02');
  assert.equal(parsePrefix('C-a'), '\x01');
  assert.equal(parsePrefix('C-Space'), '\x00');
  assert.equal(parsePrefix('C-]'), '\x1d');
});

test('prefix parsing is case-insensitive and tolerates surrounding space', () => {
  assert.equal(parsePrefix('c-a'), '\x01');
  assert.equal(parsePrefix('C-A'), '\x01');
  assert.equal(parsePrefix('  C-a  '), '\x01');
});

test('anything that is not a control chord is refused, not guessed at', () => {
  for (const bad of ['b', 'C-', 'C-ab', 'M-b', '', '  ', null, undefined, 2]) {
    assert.equal(parsePrefix(bad), null, `${bad} should not parse as a prefix`);
  }
});

test('the default prefix is stock tmux', () => {
  assert.equal(parsePrefix(DEFAULT_TMUX_PREFIX), '\x02');
});

test('page options are split out of the preferences ttyd sends', () => {
  const split = splitPreferences({ fontSize: 20, tmuxPrefix: 'C-a', theme: { background: '#000' } });
  assert.deepEqual(split.page, { tmuxPrefix: 'C-a' });
  assert.deepEqual(split.terminal, { fontSize: 20, theme: { background: '#000' } });
});

test('splitPreferences copes with ttyd sending nothing useful', () => {
  assert.deepEqual(splitPreferences(null), { page: {}, terminal: {} });
  assert.deepEqual(splitPreferences({}), { page: {}, terminal: {} });
});

test("ttyd's own isWindows flag is not an xterm option", () => {
  assert.deepEqual(splitPreferences({ isWindows: true }).terminal, {});
});

test('the toolbar follows the pointer type unless the query string overrides it', () => {
  assert.equal(toolbarWanted('', true), true);
  assert.equal(toolbarWanted('', false), false);
  assert.equal(toolbarWanted('?arg=deadbeefdeadbeef', true), true);
  assert.equal(toolbarWanted('?toolbar=0', true), false);
  assert.equal(toolbarWanted('?toolbar=1', false), true);
  assert.equal(toolbarWanted('?arg=x&toolbar=1', false), true);
  assert.equal(toolbarWanted('?toolbar=maybe', false), false, 'an unparseable value is not an override');
});

// The session picker is this page with the run-id dropped: ttyd passes ?arg=
// to dejima-attach as argv, and dejima-attach with no argument is the picker.

test('the picker address drops the run-id', () => {
  assert.equal(pickerSearch('?arg=abc123'), '');
});

test('the picker address keeps every other parameter', () => {
  // ?toolbar=1 configures this page, not the command. Losing it on the way
  // back to the picker would silently change the UI.
  const r = pickerSearch('?arg=abc123&toolbar=1');
  const p = new URLSearchParams(r);
  assert.equal(p.get('arg'), null, 'the run-id is what we are dropping');
  assert.equal(p.get('toolbar'), '1');
});

test('the picker address is already the picker when there is no run-id', () => {
  assert.equal(pickerSearch(''), '');
  assert.equal(pickerSearch('?toolbar=1'), '?toolbar=1');
});
