// Mouse report encoding, and the cell arithmetic that feeds it.
//
// Two encodings exist and the application picks, not us: SGR (DECSET 1006) if
// it asked for it, the original X10 form otherwise. X10 packs the coordinates
// into single bytes at an offset of 32, so it cannot name a column past 223 -
// which is an ordinary width on a landscape phone, let alone a desktop. There
// is nothing to send in that case, and sending a wrapped coordinate would be
// worse than sending nothing: the application would act on a cell the user did
// not touch. Hence the empty string, which callers drop.
(function (D) {
  'use strict';

  // Button codes as the xterm protocol numbers them. Motion adds 32, and the
  // wheel is reported as buttons 64/65 rather than as a separate event.
  var LEFT = 0;
  var MIDDLE = 1;
  var RIGHT = 2;
  var RELEASE = 3;
  var MOTION = 32;
  var WHEEL_UP = 64;
  var WHEEL_DOWN = 65;

  var X10_OFFSET = 32;
  var X10_MAX = 255 - X10_OFFSET; // 223

  // opts: {sgr, button, col, row, motion, release}. col/row are 1-based.
  function encodeMouse(opts) {
    var button = opts.button + (opts.motion ? MOTION : 0);
    if (opts.sgr) {
      return '\x1b[<' + button + ';' + opts.col + ';' + opts.row + (opts.release ? 'm' : 'M');
    }
    // X10 has no way to say which button was released, so every release is 3.
    var b = opts.release ? RELEASE + (opts.motion ? MOTION : 0) : button;
    if (opts.col > X10_MAX || opts.row > X10_MAX) return '';
    return '\x1b[M' + String.fromCharCode(X10_OFFSET + b, X10_OFFSET + opts.col, X10_OFFSET + opts.row);
  }

  // rect is anything with left/top/width/height - a DOMRect, or a literal in a
  // test. Clamped rather than validated: a touch that lands a pixel outside the
  // screen element (a fat finger on the last row) should report the edge cell,
  // not nothing at all.
  function cellFromPoint(x, y, rect, cols, rows) {
    var cellWidth = rect.width / cols;
    var cellHeight = rect.height / rows;
    var col = cellWidth > 0 ? Math.floor((x - rect.left) / cellWidth) + 1 : 1;
    var row = cellHeight > 0 ? Math.floor((y - rect.top) / cellHeight) + 1 : 1;
    return {
      col: Math.min(cols, Math.max(1, col)),
      row: Math.min(rows, Math.max(1, row))
    };
  }

  D.sgr = {
    LEFT: LEFT,
    MIDDLE: MIDDLE,
    RIGHT: RIGHT,
    RELEASE: RELEASE,
    MOTION: MOTION,
    WHEEL_UP: WHEEL_UP,
    WHEEL_DOWN: WHEEL_DOWN,
    X10_MAX: X10_MAX,
    encodeMouse: encodeMouse,
    cellFromPoint: cellFromPoint
  };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
