'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

// Every label the toolbar draws has to be readable on a phone held outdoors,
// which is the only place this page is ever used. WCAG AA asks 4.5:1 for text
// this size, and one of these pairings shipped at 4.31:1 in the first draft -
// gruvbox's bright_blue as a label on dark1 - which is a difference nobody
// catches by looking at a screenshot on a desk.
//
// Read out of the stylesheet rather than restated here, so a colour changed
// there is a colour checked here.

const CSS = fs.readFileSync(path.join(__dirname, '..', 'src', 'page.css'), 'utf8');

function declarationsIn(block) {
  const out = {};
  const re = /^\s*(--[a-z0-9-]+):\s*([^;]+);/gm;
  let m;
  while ((m = re.exec(block)) !== null) out[m[1]] = m[2].trim();
  return out;
}

function blockFor(selector) {
  const start = CSS.indexOf(selector + ' {');
  assert.notEqual(start, -1, 'no ' + selector + ' block in page.css');
  const end = CSS.indexOf('\n}', start);
  return CSS.slice(start, end);
}

// var(--x) chains down to a literal hex.
function resolve(vars, value, depth) {
  depth = depth || 0;
  assert.ok(depth < 10, 'variable cycle resolving ' + value);
  const m = /^var\((--[a-z0-9-]+)\)$/.exec(value);
  if (!m) return value;
  assert.ok(vars[m[1]], 'undefined variable ' + m[1]);
  return resolve(vars, vars[m[1]], depth + 1);
}

function luminance(hex) {
  const h = hex.replace('#', '');
  const parts = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255);
  const lin = parts.map((c) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)));
  return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
}

function contrast(fg, bg) {
  const a = luminance(fg);
  const b = luminance(bg);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

// Each tier's label against the surface it is drawn on. The nav tier is
// outlined rather than filled, so its label sits on the ordinary key
// background - which is precisely why its colour matters.
const PAIRINGS = [
  ['plain keys', '--key-fg', '--key-bg'],
  ['the nav tier', '--key-nav-fg', '--key-bg'],
  ['KBD', '--key-primary-fg', '--key-primary-bg'],
  ['Enter', '--key-secondary-fg', '--key-secondary-bg'],
  ['an armed latch', '--key-armed-fg', '--key-armed-bg'],
  ['a locked latch', '--key-locked-fg', '--key-locked-bg']
];

function checkBlock(selector) {
  const vars = declarationsIn(blockFor(selector));
  PAIRINGS.forEach(([what, fgVar, bgVar]) => {
    assert.ok(vars[fgVar], selector + ' does not set ' + fgVar);
    assert.ok(vars[bgVar], selector + ' does not set ' + bgVar);
    const fg = resolve(vars, vars[fgVar]);
    const bg = resolve(vars, vars[bgVar]);
    const ratio = contrast(fg, bg);
    assert.ok(
      ratio >= 4.5,
      what + ' in ' + selector + ' is ' + fg + ' on ' + bg + ' at ' +
        ratio.toFixed(2) + ':1, under the 4.5:1 a label this size needs'
    );
  });
}

test('every toolbar label meets AA against what it is drawn on', () => {
  checkBlock(':root');
});

test('turning the colours off does not turn legibility off with them', () => {
  // The grey scheme is a supported mode, not a fallback nobody looks at.
  checkBlock('body.mono-keys');
});

test('the tiers are actually distinct, or the hierarchy is decoration', () => {
  const vars = declarationsIn(blockFor(':root'));
  const bg = (v) => resolve(vars, vars[v]);
  const primary = bg('--key-primary-bg');
  const secondary = bg('--key-secondary-bg');
  const plain = bg('--key-bg');
  assert.notEqual(primary, secondary, 'KBD and Enter are filled the same colour');
  assert.notEqual(primary, plain, 'KBD is filled the same as an ordinary key');
  assert.notEqual(secondary, plain, 'Enter is filled the same as an ordinary key');
  assert.notEqual(
    resolve(vars, vars['--key-nav-border']), resolve(vars, vars['--key-border']),
    'the nav tier is outlined the same as an ordinary key'
  );
});
