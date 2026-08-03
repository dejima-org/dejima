# The terminal page

`index.html` is the frontend `bin/dejima-ttyd` hands to `ttyd` via `--index`.
It replaces ttyd's stock client with one written for touch: gestures for
scrolling, selection and dragging, and a toolbar carrying the keys a phone
keyboard does not have. See
[docs/remote-access.md](../docs/remote-access.md#reading-it-on-a-phone) for what
it does from the user's side.

## Why one file

ttyd's HTTP handler answers exactly three paths — a token endpoint, a redirect
and the index — so there is no route a separate `.js` or `.css` could be
fetched from, and `--index` replaces the whole frontend with a single file.
Inlining is the interface, not an optimisation. Nothing is fetched at runtime
either: the sandbox restricts outbound traffic to an allowlist, so a CDN
reference would not load.

`index.html` and `sources.sha256` are **generated and committed**, so a plain
checkout can serve the front door with no build step and no `node_modules`.

## Building

```sh
npm ci
node build.mjs
```

`build.mjs` inlines xterm.js, its stylesheet and the fit addon (pinned in
`package-lock.json`) together with everything in `src/`, in the order listed at
the top of the script. It also writes `sources.sha256`; `test/remote.bats`
compares that against the working tree, so a rebuild you forgot fails the suite
rather than shipping a page that is a version behind its sources.

## Tests

```sh
npm test
```

The pure parts are deliberately written as pure functions so they can be
checked without a browser: mouse report encoding and cell geometry (`sgr.js`),
the DEC private-mode tracker (`modes.js`), sticky Ctrl (`keys.js`), OSC 52
decoding (`osc52.js`), prefix parsing and preference splitting (`config.js`),
and endpoint construction (`protocol.js`). `test/remote.bats` runs these too,
so they cannot quietly stop running.

The rest — gestures, the viewport manager, the toolbar — needs a real browser
and a real phone. `docs/remote-access.md` has the manual checklist.

## Layout

| File | Role |
| --- | --- |
| `src/template.html` | page shell and the toolbar's markup |
| `src/page.css` | layout around xterm's own stylesheet |
| `src/sgr.js` | mouse report encoding, SGR and X10, and cell geometry |
| `src/modes.js` | tracks the DEC private modes that decide how a gesture is translated |
| `src/keys.js` | control codes and the sticky-Ctrl latch |
| `src/osc52.js` | the terminal's "put this on the clipboard" sequence |
| `src/config.js` | tmux prefix parsing, preference splitting, query-string overrides |
| `src/protocol.js` | ttyd's WebSocket protocol |
| `src/mouse.js` | mode tracking against a live terminal, and report emission |
| `src/gestures.js` | tap, drag, two-finger drag, long press |
| `src/viewport.js` | keeps the terminal above the soft keyboard |
| `src/toolbar.js` | button behaviour |
| `src/main.js` | wiring |

Each file attaches to a shared `DEJIMA` global rather than using modules, which
is what lets `build.mjs` concatenate them with no transformation and lets the
tests `require()` them directly.

## Upgrading xterm.js

The synthetic shift-drag in `gestures.js` drives xterm's own selection service
through DOM mouse events, which is the most internals-dependent thing here. It
is pinned for that reason. After a bump, re-check selection by long-press on a
real device before shipping.
