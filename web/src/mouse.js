// The mouse engine: mode tracking against a live terminal, cell geometry, and
// emission of the reports the application is expecting.
//
// This is the layer everything else stands on. A touch drag is consumed by the
// browser as a scroll and never becomes a mouse drag, so nothing downstream
// ever sees one - which is why tmux pane borders and nvim split separators
// cannot be dragged from a phone even though both support it. Synthesising the
// reports here is what gives them one.
(function (D) {
  'use strict';

  var sgr = D.sgr;

  function createMouseEngine(term, send) {
    var modes = D.modes.createModeTracker();

    // false from every handler is "not handled", which leaves the sequence to
    // xterm's own parser. Returning true would quietly make this file the
    // terminal's implementation of these modes.
    term.parser.registerCsiHandler({ prefix: '?', final: 'h' }, function (params) {
      return modes.set(params);
    });
    term.parser.registerCsiHandler({ prefix: '?', final: 'l' }, function (params) {
      return modes.reset(params);
    });
    // RIS. The modes are gone from the terminal's point of view, so holding on
    // to them here would leave every gesture routed to an application that is
    // no longer listening.
    term.parser.registerEscHandler({ final: 'c' }, function () {
      modes.clear();
      return false;
    });

    // The screen element is exactly cols x rows cells, which makes it the one
    // rectangle worth measuring - no font metrics, no padding arithmetic.
    function screenElement() {
      return term.element ? term.element.querySelector('.xterm-screen') : null;
    }

    function rect() {
      var el = screenElement();
      return el ? el.getBoundingClientRect() : null;
    }

    function cellAt(x, y) {
      var r = rect();
      if (!r) return null;
      return sgr.cellFromPoint(x, y, r, term.cols, term.rows);
    }

    function cellHeight() {
      var r = rect();
      return r && term.rows > 0 ? r.height / term.rows : 16;
    }

    function emit(opts) {
      opts.sgr = modes.sgrEncoding();
      var seq = sgr.encodeMouse(opts);
      // Empty means X10 could not express the coordinate. Sending a wrapped
      // one would make the application act on a cell nobody touched.
      if (seq) send(seq);
    }

    return {
      modes: modes,
      screenElement: screenElement,
      cellAt: cellAt,
      cellHeight: cellHeight,
      enabled: function () { return modes.mouseReporting(); },
      altScreen: function () { return term.buffer.active.type === 'alternate'; },
      press: function (cell) {
        emit({ button: sgr.LEFT, col: cell.col, row: cell.row });
      },
      // Only when the application asked for motion reports: under plain 1000
      // it wants clicks and nothing else, and a stream of unrequested motion
      // is noise it may well render as input.
      motion: function (cell) {
        if (!modes.motionReporting()) return;
        emit({ button: sgr.LEFT, col: cell.col, row: cell.row, motion: true });
      },
      release: function (cell) {
        emit({ button: sgr.LEFT, col: cell.col, row: cell.row, release: true });
      },
      wheel: function (cell, up) {
        emit({ button: up ? sgr.WHEEL_UP : sgr.WHEEL_DOWN, col: cell.col, row: cell.row });
      }
    };
  }

  D.mouse = { createMouseEngine: createMouseEngine };
})((globalThis.DEJIMA = globalThis.DEJIMA || {}));
