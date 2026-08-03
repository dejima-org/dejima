'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
require('../src/sgr.js');
const sgr = globalThis.DEJIMA.sgr;

const RECT = { left: 0, top: 0, width: 100, height: 50 };

test('SGR press keeps the button number and ends in M', () => {
  assert.equal(
    sgr.encodeMouse({ sgr: true, button: sgr.LEFT, col: 3, row: 7 }),
    '\x1b[<0;3;7M'
  );
});

test('SGR release keeps the button number and ends in m', () => {
  assert.equal(
    sgr.encodeMouse({ sgr: true, button: sgr.LEFT, col: 3, row: 7, release: true }),
    '\x1b[<0;3;7m'
  );
});

test('motion sets bit 5 of the button code', () => {
  assert.equal(
    sgr.encodeMouse({ sgr: true, button: sgr.LEFT, col: 1, row: 1, motion: true }),
    '\x1b[<32;1;1M'
  );
});

test('wheel notches use buttons 64 and 65 and are never releases', () => {
  assert.equal(sgr.encodeMouse({ sgr: true, button: sgr.WHEEL_UP, col: 2, row: 2 }), '\x1b[<64;2;2M');
  assert.equal(sgr.encodeMouse({ sgr: true, button: sgr.WHEEL_DOWN, col: 2, row: 2 }), '\x1b[<65;2;2M');
});

test('X10 encodes a release as button 3, losing which button it was', () => {
  assert.equal(
    sgr.encodeMouse({ sgr: false, button: sgr.LEFT, col: 1, row: 1 }),
    '\x1b[M\x20\x21\x21'
  );
  assert.equal(
    sgr.encodeMouse({ sgr: false, button: sgr.LEFT, col: 1, row: 1, release: true }),
    '\x1b[M\x23\x21\x21'
  );
});

test('X10 cannot express a coordinate past 223, SGR can', () => {
  assert.equal(
    sgr.encodeMouse({ sgr: false, button: sgr.LEFT, col: 223, row: 1 }),
    '\x1b[M\x20\xff\x21'
  );
  assert.equal(sgr.encodeMouse({ sgr: false, button: sgr.LEFT, col: 224, row: 1 }), '');
  assert.equal(sgr.encodeMouse({ sgr: false, button: sgr.LEFT, col: 1, row: 224 }), '');
  assert.equal(
    sgr.encodeMouse({ sgr: true, button: sgr.LEFT, col: 300, row: 400 }),
    '\x1b[<0;300;400M'
  );
});

test('cellFromPoint maps a point to a 1-based cell', () => {
  assert.deepEqual(sgr.cellFromPoint(0, 0, RECT, 10, 10), { col: 1, row: 1 });
  assert.deepEqual(sgr.cellFromPoint(45, 27, RECT, 10, 10), { col: 5, row: 6 });
  assert.deepEqual(sgr.cellFromPoint(99, 49, RECT, 10, 10), { col: 10, row: 10 });
});

test('cellFromPoint honours the rect origin and clamps outside it', () => {
  const offset = { left: 20, top: 10, width: 100, height: 50 };
  assert.deepEqual(sgr.cellFromPoint(20, 10, offset, 10, 10), { col: 1, row: 1 });
  assert.deepEqual(sgr.cellFromPoint(-500, -500, offset, 10, 10), { col: 1, row: 1 });
  assert.deepEqual(sgr.cellFromPoint(5000, 5000, offset, 10, 10), { col: 10, row: 10 });
});

test('cellFromPoint survives a zero-sized rect rather than returning NaN', () => {
  assert.deepEqual(
    sgr.cellFromPoint(10, 10, { left: 0, top: 0, width: 0, height: 0 }, 80, 24),
    { col: 1, row: 1 }
  );
});
