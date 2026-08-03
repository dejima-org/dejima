'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
require('../src/osc52.js');
const { base64Decode, decodeOsc52 } = globalThis.DEJIMA.osc52;

const bytes = (s) => Array.from(base64Decode(s) || []);

test('base64Decode handles every padding length', () => {
  assert.deepEqual(bytes('YQ=='), [0x61]);
  assert.deepEqual(bytes('YWI='), [0x61, 0x62]);
  assert.deepEqual(bytes('YWJj'), [0x61, 0x62, 0x63]);
  assert.deepEqual(bytes(''), []);
});

test('base64Decode refuses malformed input instead of guessing', () => {
  assert.equal(base64Decode('!!!!'), null);
  assert.equal(base64Decode('YWJ'), null, 'length not a multiple of four');
  assert.equal(base64Decode('Y==='), null, 'a single leading char cannot make a byte');
  assert.equal(base64Decode('YQ=A'), null, 'padding in the middle');
  assert.equal(base64Decode(null), null);
});

test('decodeOsc52 returns the clipboard text for any selection name', () => {
  assert.equal(decodeOsc52('c;aGVsbG8='), 'hello');
  assert.equal(decodeOsc52('p;aGVsbG8='), 'hello');
  assert.equal(decodeOsc52(';aGVsbG8='), 'hello');
  assert.equal(decodeOsc52('s0;aGVsbG8='), 'hello');
});

test('decodeOsc52 decodes UTF-8, not latin-1', () => {
  assert.equal(decodeOsc52('c;w6ljaG8='), 'écho');
});

test('decodeOsc52 rejects a query, an empty payload and garbage', () => {
  assert.equal(decodeOsc52('c;?'), null, 'a read request, which this page does not answer');
  assert.equal(decodeOsc52('c;'), null, 'a clear, with nothing to write');
  assert.equal(decodeOsc52('c;!!!!'), null);
  assert.equal(decodeOsc52('aGVsbG8='), null, 'no selection field at all');
  assert.equal(decodeOsc52(''), null);
  assert.equal(decodeOsc52(null), null);
});

test('a base64 payload containing a semicolon is not truncated', () => {
  assert.equal(decodeOsc52('c;YTtiO2M='), 'a;b;c');
});
