# Remote access

[← dejima README](../README.md)

**Off by default, and nothing here starts itself.** Remote access is one
config switch plus work you do by hand: two systemd user units to install,
a reverse proxy to write, an SSH key to authorise. Until you have done all
of it, `dejima` runs with no remote-access behaviour at all. See
["What `off` means"](#what-off-means) for the specifics.

## What it is

A way to get back to a session that is *already running* on your machine,
from a phone on the same network, when it stops to ask you something. The
session pushes a notification; you tap it and land in the tmux window that
session is running in.

It is not a way to *start* a session, and it is not a hosted service.
**Don't open it to the public internet.**

## What it costs you

**A front door here is a host shell, not a view of one sandbox.** Both of
them - SSH and web - end at a tmux client on your own tmux server, and a
tmux client is one prefix key away from a new window that has nothing to do
with any sandbox. Everything below follows from that single fact: it is why
the web listener is on loopback, why the proxy needs authentication, and why
the address that proxy binds is the one step to get right.

So what turning this on adds is **ingress, on your own network**. Anyone who
can reach the address you put the front door on can have that host shell,
and "on my LAN" is the whole of the perimeter you are getting - there is no
second factor here, no per-session authorisation, and no audit of who
attached. The two things holding that line are:

- **[The bind address](#the-bind-address-is-the-one-thing-to-get-right).**
  `ttyd` binds `127.0.0.1` and your proxy must bind one specific LAN
  address - never the wildcard, never a Docker bridge.
- **Authentication on the proxy.** `ttyd` carries no credential of its own,
  so a `server` block without `auth_basic` is an unauthenticated host shell
  for everyone on that network.

What it does **not** add is a way *out* of a sandbox. Configured as
described below, a compromised session cannot reach `ttyd`, cannot reach
your proxy, and gains nothing from the fact that your phone can: it has a
route to exactly one host address, and neither front door is on it. That
property needs stating exactly, because it is the one a plausible-looking
mistake inverts - a proxy bound to `0.0.0.0` or to a bridge address is a
front door opening *inward*, and that is a full sandbox escape rather than a
degradation. [Verifying it](#verifying-it) is two commands, and worth
running.

## `[remote-access]`

A section of the single config file, at `~/.config/dejima/config`
(`$DEJIMA_CONFIG_DIR` relocates the whole config tree, same as it does for
approvals):

| Key | Default | Purpose |
| --- | --- | --- |
| `enabled` | `off` | the switch - nothing below runs until this is `on` |
| `ntfy_url` | unset | ntfy topic to push notifications to. `dejima-notify-watch` refuses to start without it; nothing else reads it |
| `base_url` | unset | public base URL of the web front door, used to build the notification's deep link. Absent, pushes still go out - just with no link on them |
| `ttyd_port` | `7681` | loopback port `ttyd` listens on. The reverse proxy has to `proxy_pass` to the same one |
| `ttyd_font_size` | unset | terminal font size in px, 8-72. Applies to *every* client, phone and desktop alike - see "Reading it on a phone". Unset passes no option at all and leaves `ttyd` on its own default |
| `ttyd_focus_on_tap` | unset | whether tapping the terminal raises the soft keyboard. Unset means no on a touch device and yes on a desktop, which is almost always what you want; `on` or `off` forces it. Overridable per client with `?focus=1` / `?focus=0` |
| `ttyd_tmux_prefix` | unset | the tmux prefix the terminal page's `PREFIX`, `◀W`, `W▶` and `ZOOM` buttons send, written as a control chord: `C-a`, `C-b`, `C-Space`, `C-@`, `C-_`, `C-?`. Unset leaves the page on stock tmux's `C-b`. See "Reading it on a phone" |

`ntfy_url` and `base_url` must carry an explicit `http://` or `https://`
scheme; a value without one is refused rather than guessed at, because
`curl` reads a leading `-K/path` as an *option* that takes the request's URL
from that file instead. Values are restricted to
`A-Za-z0-9:/._~?=%@+-`: no whitespace and nothing shell-active, since these
end up in an HTTP header and in a URL handed to a phone.

**A malformed config is a hard failure, not a warning.** The whole file is
validated on every read, not just the key being asked for: an unknown key, a
value outside that character set, or a line that doesn't parse makes
`dejima-ttyd` and `dejima-notify-watch` refuse to start and say which line
was wrong. A `ttyd_port` that isn't a number in 1-65535 is refused the same
way, as is a `ttyd_font_size` outside 8-72 - a size big enough to make one
glyph wider than the viewport renders a terminal that shows nothing, which
reads as a broken front door rather than as a typo three sections away. A
`ttyd_tmux_prefix` that is not a control chord is refused here too, rather
than on the phone, hours later, by whoever presses `PREFIX` and gets nothing.

`dejima-ttyd` and `dejima-notify-watch` are the two scripts that read a
*value* out of the config, so a typo anywhere in the file refuses their
start. `dejima` reads values too (`audit dir` among them) and refuses the
same way. `dejima-attach` alone only asks `remote_enabled` - deliberately
bypassing the whole-file validation, so a typo elsewhere in the config can't
lock you out of the terminal you'd fix it from.

```
# ~/.config/dejima/config - substitute your own topic and hostname
[remote-access]
enabled = on
ntfy_url = https://ntfy.example.invalid/your-topic-here
base_url = https://dejima.example.invalid
ttyd_port = 7681
# ttyd_font_size = 20      # optional, and applies to the desktop too
# ttyd_tmux_prefix = C-a   # optional; the page assumes stock C-b without it
```

**Editing this changes nothing until the services restart.** Every value
is read once, at process start - `dejima-ttyd` reads `ttyd_port`,
`ttyd_font_size` and `ttyd_tmux_prefix` and then `exec`s `ttyd` with them
baked into its argv. So:

```sh
systemctl --user restart dejima-ttyd.service
systemctl --user restart dejima-notify-watch.service   # if ntfy_url changed
pgrep -a ttyd    # confirm the argv is what you just configured
```

Skipping this is quiet rather than loud: nothing warns, and the front door
keeps serving with the old settings, which reads as "the setting had no
effect" rather than as "the process is older than the file".

## How it works

Almost none of this is in the sandbox. The container writes one empty file
and knows nothing else about the feature; everything that turns that into a
notification, and everything that puts a terminal in front of you
afterwards, runs on the host as your own user.

### The session asks you something

```
 ┌─ the sandbox container ────────────────────────────────────────────┐
 │  claude code, at a Notification or Stop hook                       │
 │       │                                                            │
 │       │  hooks/dejima-notify.sh writes an empty file named         │
 │       ▼  `waiting` or `done` - no content, no stdin, no network    │
 └───────┼────────────────────────────────────────────────────────────┘
 ════════╪═══ container boundary - one bind-mounted directory ═════════
 ┌───────▼─── your machine, as your user ─────────────────────────────┐
 │  ${XDG_RUNTIME_DIR}/dejima/notify/<run-id>/waiting                 │
 │       │                                                            │
 │       │  inotify, or a ~6s poll where inotify-tools is absent      │
 │       ▼                                                            │
 │  dejima-notify-watch  (systemd --user)                             │
 │       │  consumes the marker by NAME; never reads its content      │
 │       │  every byte of the push is composed from host-side data    │
 │       ▼                                                            │
 └───────┼────────────────────────────────────────────────────────────┘
 ════════╪═══════════════ off your machine ════════════════════════════
         │  curl
         ▼
         your ntfy topic ──── push ────►  your phone
                                          "dejima: <project> needs input"
                                          link: <base_url>/?arg=<run-id>
```

The marker directory is the sandbox's entire surface here, and it is
one-way: a name, out. Nothing the session writes reaches the push, which is
why the notification says a project needs input and never what it is asking.
[Notifications](#notifications) has the detail, including where that
guarantee actually lives.

### You come back

```
    browser, on the link from the push          any plain SSH client
         │                                              │
         │  https://<base_url>/?arg=<run-id>            │  ssh dejima-box
         │  HTTP Basic over TLS                         │  key with a
         ▼                                              ▼  forced command
 ════════╪══════════════════ your LAN ══════════════════╪══════════════
 ┌─ your machine, as your user ───────────────────────────────────────┐
 │  nginx, listening on ONE LAN address        sshd                   │
 │   TLS + auth_basic, plus a default_server    authorized_keys with  │
 │   that refuses every other name              a forced command      │
 │       │                                              │             │
 │       │  proxy_pass http://127.0.0.1:7681            │             │
 │       ▼                                              │             │
 │  ttyd --interface 127.0.0.1 --check-origin --url-arg │             │
 │       │                                              │             │
 │       └──────────────────────┬───────────────────────┘             │
 │                              ▼                                     │
 │                    dejima-attach [<run-id>]                        │
 │                              │  a grouped tmux session             │
 │                              ▼                                     │
 │                    YOUR TMUX SERVER                                │
 │                     the sandbox's window - and every other         │
 │                     window on it, one prefix key away              │
 └────────────────────────────────────────────────────────────────────┘
 ═════════════════════ container boundary ═════════════════════════════
 ┌─ the sandbox container ────────────────────────────────────────────┐
 │  routes to the Docker bridge gateway - your host - and to nothing  │
 │  else of yours. Neither front door is on that address, which is    │
 │  the whole reason `ttyd` is on loopback and nginx is on one        │
 │  named LAN interface. A proxy on `0.0.0.0` or on a bridge puts a   │
 │  host shell in here.                                               │
 └────────────────────────────────────────────────────────────────────┘
```

The web door is the one the notification links into: the browser hits your
reverse proxy, which authenticates and forwards to a `ttyd` that only this
host can open a socket to, and `ttyd` runs `dejima-attach` with the run id
from `?arg=`. The SSH door skips all of that. It is a key in your own
`authorized_keys` pinned to a forced command, so a plain SSH app on the
phone runs `dejima-attach` and nothing else no matter what it asks to run,
and lands on a numbered picker of live sessions. It needs no proxy, no
`ttyd`, and no notification to have been sent.

Both converge on `dejima-attach`, and both end at *your* tmux server. That
convergence is the point: the controls worth spending effort on are the two
front doors, because behind them there is no further boundary to cross - a
grouped tmux session shares every window on the server, and the prefix key
opens new ones regardless.

### What `off` means

With `[remote-access] enabled` off (the default), `dejima` builds a
`docker compose` invocation with nothing remote-access in it: no
session state is written, no marker directory is created or mounted, and no
notification hook is registered. `dejima-attach`, `dejima-ttyd` and
`dejima-notify-watch` each refuse to run at all. `install.sh` symlinks those
three onto `PATH` and stops there - it runs no `systemctl`, copies no unit,
and starts nothing.

## The bind address is the one thing to get right

This is the step that carries the whole feature's security, and the only one
where a plausible-looking choice is a full sandbox escape.

`docker/init-firewall.sh` deliberately ACCEPTs container OUTPUT to the
container's default-route address - the Docker bridge gateway, which is your
host. That is the one host address a sandbox can reach at all. Combine it
with the fact above (a tmux client is a host shell) and the consequence is
direct: **a front door the sandbox can reach is a compromised session's own
escape hatch.**

So:

- `ttyd` is bound to `127.0.0.1` by `dejima-ttyd`, hardcoded, not
  configurable. The container has no route to your host's loopback, so
  nothing but a process on this host can open that socket.
- **The reverse proxy has to run on that same host** - the dejima box, the
  one your sandboxes start on. That is not a preference, it is what the
  loopback bind implies: `proxy_pass http://127.0.0.1:<ttyd_port>` only
  resolves to `ttyd` from the same machine. If you already run a proxy on a
  *different* box, do not point it here - reaching `ttyd` from there would
  mean binding `ttyd` to a routable address, which is precisely the escape
  this whole section exists to prevent. Put a second, small proxy on the
  dejima box instead.
- That proxy must bind **one specific address, on the dejima box's LAN
  interface**. Never the wildcard - a bare `listen 443 ssl;` is every
  interface *including* the Docker bridges - never `0.0.0.0`, and never a
  bridge address.

## Picking the address

`ip -br addr` on the dejima box lists more candidates than you want, because
Docker adds its own. It looks something like this:

```
lo               UNKNOWN  127.0.0.1/8 ::1/128
enp3s0           UP       192.0.2.24/24 <a link-local v6 address>
docker0          UP       <docker's own subnet>
br-9f3c1a2b4d5e  UP       <docker's own subnet>
```

Only the physical LAN interface qualifies - `enp3s0` here; yours may be
`eth0`, `wlan0`, `enp0s31f6`, or a bond. So `listen 192.0.2.24:443 ssl;`,
using your own address in place of that one.

Everything else on that list is disqualified, and two of them dangerously
so. `lo` is where `ttyd` already is. `docker0` and every `br-<hash>` are
Docker bridges - **these are the addresses a sandbox can reach**, so a proxy
bound to one is a front door opening inward. If you are unsure which lines
those are, ask for exactly them:

```sh
ip -br addr show type bridge   # every address here is disqualified
```

Cross-check from the other side, too: the address a running sandbox has a
route to is the one to avoid, and the container will tell you which it is -
`docker exec <container> ip route | grep default` names it.

Afterwards, `ss -ltnp | grep <ttyd_port>` should show `ttyd` on `127.0.0.1`
only, and `ss -ltnp` on your proxy's port should show the single LAN address
you chose - not `*` and not `0.0.0.0`.

## Verifying it

Verify rather than assume. With a sandbox running, from inside it (adjust
`7681` if you changed `ttyd_port`, and `443` to whatever port your proxy
listens on):

```sh
# the bridge gateway - the only host address this container can route to
gw=$(ip route | grep default | cut -d' ' -f3)

# both should fail: the loopback ttyd, and the front door's own port
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$gw/7681" && echo BAD || echo ok
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$gw/443"  && echo BAD || echo ok
```

`BAD` on either line means stop and fix the bind before going further -
whatever answered is reachable from inside the sandbox. The first line is
also what catches a distro `ttyd.service` still running on that port, which
is why this is worth doing even if you are confident about the proxy. `test/runtime.bats`
asserts this same containment property against a live container (with a
positive control on the same path, so a passing result can't come from the
container reaching nothing), and it passes on a real Docker host.

## SSH front door

Generate a key that exists only for this, and give it a forced command:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/dejima-phone -C phone
```

Then one line in `~/.ssh/authorized_keys`, with the full path to the symlink
`install.sh` made:

```
restrict,pty,command="/home/<you>/.local/bin/dejima-attach" ssh-ed25519 AAAA... phone
```

`restrict` turns off port forwarding, agent forwarding, X11 and everything
else; `pty` adds back the one thing a terminal needs; `command=` runs
`dejima-attach` no matter what the client asks to run. Nothing the phone
sends is interpreted as a command, so this needs no client-side
"run this on connect" support - any plain SSH app lands on the picker.

It has to be the **same Unix user** that runs `dejima`: tmux sockets are
per-user, and `dejima-attach` talks to the tmux server of whoever runs it.
Options are per-key, so your normal key still gets a normal shell - worth
confirming both after you add the line.

## Web front door

Needs `ttyd` **1.7.4 or newer**. `-W`/`--writable` arrived in 1.7.4, so an older build rejects the flag and
`dejima-ttyd` fails at every start. Your distro's package may well be
too old: Debian bookworm's is 1.7.3 and Ubuntu 22.04's is 1.6.3, neither of
which has the flag - Ubuntu 24.04's 1.7.4 does. Check with `ttyd --version`,
and take an upstream release binary if the packaged one is behind.

On Debian there is a middle option: sid packages **1.7.7**, and you can take
that one package without moving the rest of the system to unstable. sid is
not a configured source on a stable install, so add it - and pin it *below*
your normal release, or the next `apt upgrade` follows it:

```sh
echo 'deb http://deb.debian.org/debian unstable main' \
    | sudo tee /etc/apt/sources.list.d/sid.list

# without this pin the whole system drifts to unstable
printf 'Package: *\nPin: release a=unstable\nPin-Priority: 10\n' \
    | sudo tee /etc/apt/preferences.d/99-sid

sudo apt update
sudo apt install -t unstable ttyd    # -t overrides the pin, for this package
```

Read what `apt` proposes before agreeing to it. One package from sid drags
its libraries along, and if the plan includes `libc6` you are no longer
taking one package - back out and use an upstream release binary instead.
`apt_preferences(5)` has the details.

**Installing the package opens a door of its own. Close it.** However you get
`ttyd` from a distro repository - stable, sid, Ubuntu - the package ships a
*system* service that systemd enables and starts on install. It serves a
login prompt, and because it passes no `--interface` of its own it binds
**every** interface, the bridge address a sandbox routes to included. It
listens on `ttyd`'s default port, which is the port this feature defaults to
as well.

Two consequences, and the second is the one that hides:

- A host login prompt is now reachable *from inside every container you run*,
  put there by the act of installing the package.
- It holds the port, so `dejima-ttyd` fails to bind at every start while your
  reverse proxy proxies to the distro's `ttyd` instead. You get your own
  password prompt and then a host login shell, on the hostname you set up for
  dejima, with nothing along the way appearing broken.

```sh
systemctl status ttyd.service              # almost certainly active
sudo systemctl disable --now ttyd.service
sudo systemctl mask ttyd.service           # so reinstalling cannot revive it
```

`dejima-ttyd` refuses to start when anything already holds its port and
names this as the likely cause, rather than leaving you with `ttyd`'s
one-line bind error in a unit nobody is watching. That is a diagnostic, not a
fix: the listener is there from the moment the package lands, whether or not
you ever run `dejima-ttyd`.

`dejima-ttyd` reads `ttyd_port` and launches
`ttyd --interface 127.0.0.1 --port <port> --check-origin --url-arg --writable dejima-attach`.
Two of those are load-bearing:

- **`--check-origin`** is not tidiness. Without it `ttyd` does no origin
  validation at all, and browsers do not apply the same-origin policy to
  WebSockets - they do attach the cached credential for the target origin.
  Any page loaded in an authenticated operator's browser could open
  `wss://<front-door>/ws` and be handed this host shell, with no interaction
  beyond visiting the page. Proxy authentication cannot stop that; it is
  satisfied by the victim's own browser.
- **`--url-arg`** is what lets the notification's deep link name a session
  (`?arg=<run-id>`). It reaches `dejima-attach` as argv, never as a shell
  word, and has to match the run-id shape before it is used for anything.

Install the unit by hand - it ships disabled, and `install.sh` will not do
this for you:

```sh
mkdir -p ~/.config/systemd/user
cp systemd/dejima-ttyd.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now dejima-ttyd.service
```

It is a **user** unit, not a system one, and it repeats no configuration:
`ExecStart` is `%h/.local/bin/dejima-ttyd`, and the bind address and port
live in the script and the config so the two cannot drift.

Then put a reverse proxy in front of it. Adapt
`docs/nginx-dejima.conf.example` - it will not load as written, deliberately,
so it can never become a live config by being dropped into `sites-enabled`
and forgotten. What matters in it:

- **Authentication on every server block.** `ttyd` is started with no
  credential of its own, because the loopback bind means only this host can
  reach it - the proxy is the entire gate. A block without `auth_basic` is
  an unauthenticated host shell on your network.
- **A `default_server` that refuses.** nginx picks a server block by
  SNI/`Host`, and when nothing matches it serves the **default** for that
  listen address - which, if the front door is the only block on it, is the
  front door. `server_name` on its own therefore isolates nothing: the vhost
  answers to *every* name that resolves to that address, including the box's
  own hostname. The example ships a first block that is `default_server` and
  does nothing but `ssl_reject_handshake on;`, so only the name you chose
  gets through. If you already have a default server on that address, keep
  the one you have - just make sure it doesn't fall through to this vhost.
- **TLS.** HTTP Basic sends the password on every request, and the terminal
  itself carries whatever the session is working on.
- **`proxy_set_header Host $http_host;`**: `$http_host`, not `$host`.
  `--check-origin` compares the client's `Origin` against the `Host` header,
  and nginx's `$host` has the port stripped while `ttyd` keeps the port in
  what it compares unless it is 80 or 443. On a vhost listening anywhere
  else - 8443, say - `$host` makes `ttyd` compare `name:8443` against `name`
  and refuse every WebSocket: the page loads, the terminal never connects,
  and the only sign is a "refuse to serve WS client from different origin"
  line in `ttyd`'s log.
- **A long `proxy_read_timeout`.** An attached terminal sits idle for hours;
  nginx's default is 60 seconds.

## Reading it on a phone

`dejima-ttyd` launches `ttyd` with `--index web/index.html`, which replaces
`ttyd`'s stock frontend with one written for touch. This is the default and
there is nothing to turn on.

`ttyd`'s own page is close to unusable on a phone for anything beyond typing,
and not because of a setting anyone missed. xterm.js turns a tap into a mouse
click, but a touch *drag* is consumed by the browser as viewport scrolling and
never becomes a mouse drag - so nothing downstream ever sees one. tmux binds
`MouseDrag1Border` to `resize-pane -M` by default and nvim resizes splits from
separator drags whenever `mouse` is on; both have always worked, and simply
never received a drag event from a touch client. The same missing drag is why
selecting text is impossible, and scrolling an application's output with it.
Then there is no Ctrl key, the tmux status bar's window names are a few pixels
wide, and `ttyd` serves no viewport meta tag at all - so a phone lays the page
out at a virtual desktop width and scales the result down, which no font size
can rescue.

### Gestures

| Gesture | What it does |
| --- | --- |
| Tap | Clicks that cell, exactly as before, and focuses the terminal |
| Two-finger drag | Scrolls. A wheel report when the application is reading the mouse, xterm's own scrollback when it is not |
| One-finger drag, `DRAG` off | Scrolls, identically |
| One-finger drag, `DRAG` on | A real mouse drag: press, move, release |
| Long press ~0.4s, then drag | Selects text; releasing copies it to the phone's clipboard |

`DRAG` is a toolbar toggle rather than something inferred, so with it off a
finger drag inside a mouse-aware application never starts doing something
else the moment you meant to scroll. Two-finger
scrolling works in both states, so a `DRAG` you forgot to turn off can never
leave you without a way to scroll.

With `DRAG` on, dragging a tmux pane border resizes the pane and dragging an
nvim split separator resizes the split. Neither needs any server-side
configuration - they are stock tmux and nvim behaviour; the page's only
contribution is delivering the drag.

### Toolbar

```
ESC   CTRL   TAB   ←   ↓   ↑   →   ⏎
PREFIX  ◀W   W▶   SESS   ZOOM   DRAG   PASTE   KBD
```

- `CTRL` is sticky: one tap arms it for the next key, a second tap locks it on,
  a third releases it. Armed and locked are different colours, because they are
  the same button.
- `PREFIX` sends the tmux prefix - `C-b` unless `ttyd_tmux_prefix` says
  otherwise - so tmux's own bindings stay reachable: `PREFIX` then `w` opens
  the window list, `PREFIX` then `[` enters copy mode.
- `◀W` and `W▶` are prefix + `p` / prefix + `n`. They are the answer to the
  window names in the status bar being unhittable on a phone: two large targets
  that are always in the same place.
- `SESS` goes back to the session picker, for switching to another sandbox
  without closing the tab. It reloads the page without the run-id, which is
  what makes `dejima-attach` show the list again. The session you leave is
  unaffected: each client gets its own tmux session grouped onto the real one,
  and only that view is reaped when you detach.
- `ZOOM` is prefix + `z`, toggling tmux's pane zoom - the fastest way to make
  one pane usable on a small screen.
- `PASTE` reads the phone's clipboard and sends it, wrapped in bracketed-paste
  markers when the application has asked for them. It needs a secure context;
  on an `http://` front door the browser refuses the read and the page says so
  rather than doing nothing.
- `⏎` sends Enter, which is the key a session asks for most and the one a soft
  keyboard puts furthest from a thumb.
- `KBD` raises the soft keyboard, which is otherwise awkward to get back once
  it has been dismissed.

**Tapping the terminal does not raise the keyboard.** On a phone, tapping is
also how you scroll and select, so every one of those taps used to summon the
keyboard and cost a second tap to put it away. `KBD` is the deliberate way to
ask for it. A desktop is unchanged - there is no soft keyboard to raise, and
clicking to focus is what a terminal does.

Set `ttyd_focus_on_tap = on` to get the old behaviour for every client, or add
`?focus=1` to the URL for one. `?focus=0` forces it off on a desktop.

Copying *out* works through OSC 52: anything that emits it - tmux with
`set-clipboard on`, nvim, your own yank binding - lands in the phone's
clipboard. Nothing needs to be installed for that, and nothing here assumes
any particular relay exists. That is the same path the sandbox already uses
(`docker/sandbox-clipboard.lua` sets nvim up to emit it), so it is worth being
explicit about what it means: anything running in the session can put text on
the clipboard of whatever you are reading it from.

This page is **more permissive than most native terminals**, so the two front
doors are not equivalent here: xterm gates OSC 52 writes behind
`allowWindowOps`, off by default; kitty prompts; Alacritty needs configuring.
Two things bound it. Every write raises a toast naming how much was written,
because a clipboard that changes silently is one you paste from believing you
know what is on it; and a payload over 100KB is refused outright, since a yank
is a selection rather than a stream.

The step that matters is `PASTE`, not the write. Into an application with
bracketed paste on - an editor, or a shell that supports it - the text arrives
as data and nothing runs. Into one without it, a plain shell being the case to
think about, a trailing newline is indistinguishable from pressing Enter, so
`PASTE` strips trailing newlines: the text lands at your prompt and you press
Enter yourself. Line breaks in the *middle* still arrive as Enter, which is
true of pasting into any terminal without bracketed paste; `PASTE` says so
when it sends one rather than leaving you to assume otherwise.

The toolbar and the gestures appear only for a coarse pointer, so a desktop
browser gets a plain terminal.
`?toolbar=0` and `?toolbar=1` on the URL override that either way without
touching any config - useful for a screenshot, or for driving the page from a
desktop browser deliberately.

### What replacing the frontend costs

`ttyd`'s stock page carries zmodem, trzsz and sixel support, and `--index`
replaces the page, so those go with it. In an agent sandbox they are rarely
what anyone reaches for, and this is the trade. Removing `--index` from
`bin/dejima-ttyd` restores the stock client and everything it carries.

### Font size

If the text is still smaller than you want once the layout is honest, set
`ttyd_font_size` in `[remote-access]` (8-72). Be aware of what it costs:
**it applies to every client.** `ttyd` 1.7.7 accepts client options only at
launch - the URL-query override that would let a deep link carry its own size
landed upstream after 1.7.7 was cut - so there is no way from here to give a
phone one size and the desktop another. A larger size also means fewer
columns, and because attaching shares the window with your desktop session,
tmux resizes that window to whichever client used it last. Start by fixing the
viewport and only reach for this if you still need it.

### Rebuilding the page

`web/index.html` is generated from `web/src` and **committed**, so a checkout
has it and nothing has to run a build to use the front door. It has to be one
file: `ttyd` serves exactly three paths - a token endpoint, a redirect and the
index - so there is no route a separate `.js` or `.css` could be fetched from,
and the sandbox's egress allowlist rules out a CDN. Everything, xterm.js
included, is inlined.

After editing anything under `web/src`:

```sh
cd web && npm ci && node build.mjs
```

The test suite fails if the page is older than its sources, so a rebuild that
was forgotten is caught rather than shipped. See `web/README.md`.

### Checking it on a real device

Everything below needs a phone; none of it can be automated, and the parts that
can be checked without one already are (`web/README.md`). Worth walking once
after any change to `web/`:

1. With `DRAG` on, drag a tmux pane border - the pane resizes.
2. With `DRAG` on, drag an nvim split separator - the split resizes.
3. Two-finger scroll in tmux copy mode scrolls it.
4. Two-finger scroll in a terminal nested inside nvim scrolls *that* terminal,
   not the outer view.
5. `◀W` and `W▶` switch tmux windows; `ZOOM` toggles pane zoom.
6. Long press and drag selects text, and releasing puts it on the clipboard.
7. `PASTE` inserts the phone's clipboard.
8. Yanking inside tmux or nvim lands in the phone's clipboard, via OSC 52.
9. `CTRL` then `c` interrupts; tapping `CTRL` twice locks it on.
10. Raising the soft keyboard does not cover the prompt, and rotating refits.
11. On a desktop browser: a plain terminal, no toolbar, mouse unchanged.

Android is the primary target. iOS Safari differs in both touch handling and
`visualViewport` behaviour and has not been tested.

### If your phone is showing you the old page

`ttyd` sends the index with no `Cache-Control`, no `ETag` and no
`Last-Modified` - `src/http.c` sets the status, content type, encoding and
length, and nothing else - and a response carrying neither freshness
information nor a validator is cacheable for as long as the browser feels like
it, which on a phone means indefinitely. So a phone that visited the front door
before this page existed can go on rendering the old one. The nginx example
sends `Cache-Control: no-store`, which closes it going forward; to check right
now, load the front door in a private tab.

## Typing on a phone

Text you already typed reappears a batch at a time, sometimes cascading into
another batch. Backspacing clears it; a few characters later it happens
again.

**It is the keyboard's autocorrect**, and two things locate it there. The
duplicated characters are real input you can backspace over rather than a
redraw artifact, and the WebSocket runs over TCP, which cannot deliver the
same bytes twice - so the browser is emitting them. And it reproduces on
demand: a long run of digits never duplicates, while ordinary words duplicate
on every correction the keyboard makes - `fix` to `fox`, `lets` to `let's`.
When a soft keyboard *replaces* a span it has already committed, xterm.js
re-sends the whole contents of its hidden input element instead of the
difference, so the entire line replays.

xterm.js already asks the keyboard not to do this - it sets `autocorrect`,
`autocapitalize` and `spellcheck` to off on that element as it creates it -
and Android ignores all three. This is a general `ttyd`/xterm.js interaction
with predictive keyboards, and there is no lever here, in the proxy or in
`dejima-ttyd`, that reaches it.

So use a keyboard with nothing to correct against. **Unexpected Keyboard**
(F-Droid or Play Store) was written for Termux users and fits well: its word
suggestions need a dictionary you download yourself, so a fresh install has
nothing to autocorrect with, and Ctrl, Alt, Esc, Tab, the arrows and the
function keys are all real keys, reached by swiping a key toward the corner
the symbol is printed in. Android's keyboard switcher makes it a per-session
choice rather than a replacement for the keyboard you use for everything
else. The toolbar carries Ctrl, Esc, Tab and the arrows, so a third-party
keyboard is not the price of admission here; it is the fix for the
autocorrect bug and nothing more.

Turning autocorrect off in the keyboard you already have fixes it too, at the
cost of losing the correction everywhere else.

## Behind another reverse proxy

Terminating TLS somewhere else and forwarding here is a supported shape, but
read this first: it moves the front door out of the LAN threat model
everything above is written against. If the outer proxy is internet-facing,
`auth_basic` over TLS is now the only thing between the public internet and
a host shell. Put something stronger in front of it, and take the
[security notes](security.md) as the floor rather than the ceiling.

The mechanical part has four requirements at the outer hop, and each one
fails differently:

```nginx
proxy_ssl_server_name on;                    # else: TLS handshake refused
proxy_ssl_name  dejima.example.invalid;
proxy_set_header Host dejima.example.invalid;   # exactly once - see below
proxy_http_version 1.1;                      # else: page loads, terminal never connects
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_read_timeout 1d;                       # else: dropped after 60s idle
```

- **`proxy_ssl_server_name` is off by default**, so nginx proxying to an
  HTTPS upstream sends no SNI at all. The inner nginx sees a handshake with
  no name, hands it to the `default_server` - which exists precisely to
  refuse unrecognised names - and you get a 502 at the outer hop.
- **Set `Host` exactly once.** `proxy_set_header` is additive within a
  configuration level rather than overriding, so declaring `Host` twice
  sends *two* `Host` headers and the inner nginx answers 400 to all of it.
  The easy way to do this by accident is `include proxy_params;` (Debian
  ships one that already sets `Host $http_host`) plus your own `Host` line
  in the same block.
- **A literal, not `$host` or `$http_host`.** The value has to be the
  hostname the *browser* used, because that is what `ttyd`'s
  `--check-origin` compares the `Origin` against at the far end. A literal
  also guarantees it agrees with `proxy_ssl_name`.
- **`Upgrade`/`Connection` and the timeout are needed at every hop**, not
  just the inner one. Miss them outside and the page loads while the
  terminal never connects - the same symptom the inner config produces, from
  a different place.

nginx logs the *reason* for a 400 at `info` level, which is below the
default. When something here is wrong and the access log only says `400`,
set `error_log /var/log/nginx/error.log info;` on the inner proxy, reproduce
once, and it names the cause outright. Turn it back down afterwards. To
establish which hop is at fault, bypass the outer one from the dejima box
itself:

```sh
curl -vk --resolve dejima.example.invalid:443:<dejima-box-lan-ip> \
    https://dejima.example.invalid/
```

A `401` there means the inner config is correct and the fault is entirely in
what the outer proxy sends.

## Notifications

`dejima` registers `hooks/dejima-notify.sh` as a `Notification` and `Stop`
hook for a remote-enabled session, into the throwaway settings override layer
it already generates - never into your real `~/.claude/settings.json`. Your
own hooks keep running alongside it, since Claude Code merges hooks across
layers rather than replacing. The layer is mounted read-only, so a session
cannot unregister its own hook. The hook writes one empty file named
`waiting` or `done` into this run's marker directory: no content, no stdin,
no network.

On the host, `dejima-notify-watch` turns those markers into ntfy pushes.
Same installation shape as above:

```sh
cp systemd/dejima-notify-watch.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now dejima-notify-watch.service
```

`inotify-tools` is optional - without `inotifywait` the watcher degrades to
a roughly six-second poll rather than failing (a one-second floor under the
loop plus a five-second sleep). Repeat markers for the same session and
event inside 60 seconds are debounced (`[remote-access] debounce` overrides
that).

One gotcha, because it fails silently: both sides resolve the marker root as
`${XDG_RUNTIME_DIR:-/tmp}/dejima`, so they only meet when they agree on
`XDG_RUNTIME_DIR`. systemd sets it for user units and a login shell gets it
from pam_systemd, but a run from a context with neither - a bare `su`, cron,
a tmux server started before login - writes to `/tmp/dejima` while the unit
watches `/run/user/<uid>/dejima`. No push is sent and nothing is logged.
Check with `systemctl --user show-environment`.

The same directory is why you probably want lingering on:

```sh
loginctl enable-linger "$USER"
```

Both are *user* units. Without lingering they stop at logout and
`/run/user/<uid>` is destroyed with the session, taking the registry and
every marker with it - so a sandbox left in a detached tmux session has no
front door and sends nothing until you log in again. It fails closed, but
invisibly, and on the same `XDG_RUNTIME_DIR` as the gotcha above.

**The marker directory is a write channel into your runtime tmpfs**, and
nothing bounds it. `/run/user/<uid>` is RAM-backed and sized at a fraction of
physical memory, so a session filling `/run/dejima-notify` degrades your
whole login session - D-Bus, the systemd user manager - not just dejima. A
session can already fill the workspace mount, so this is an increment rather
than a new exposure, but a RAM-backed filesystem fails harder and sooner.
There is deliberately no quota here; `rm -rf` on that run's marker directory (or
logging out, which discards the tmpfs) is the recovery.

**What a notification contains.** A title of `dejima: <project> needs input`
(or `dejima: <project> finished`), a fixed one-line body, and - when
`base_url` is set - a click link of `<base_url>/?arg=<run-id>` that opens the
web front door already attached to that session. `<project>` is the
workspace directory's name, taken from the host-side registry and reduced to
`A-Za-z0-9._-`.

**And nothing about what Claude is actually asking.** That absence is
deliberate, not a missing feature: your phone is outside the sandbox, so no
sandbox-controlled bytes are allowed to reach it. The question itself is on
the terminal you are about to attach to; the push exists only to tell you to
go look.

The guarantee for that is host-side, and it is worth being precise about
where it lives. The in-container hook's `waiting|done` whitelist is **not**
it - a compromised session owns its own bind-mounted marker directory and
can create any file name in it, hook or no hook. What holds is
`dejima-notify-watch`: it iterates a literal two-name enum rather than
reading the directory, so a name outside it is never stat'd, read or
removed; it never reads marker *content*; and it consumes markers with
`rm -f`, which unlinks a symlink instead of following it. Every byte it
sends - title, body, headers, click URL - is composed from host data. That
last point is what the enum is really for: ntfy's own headers include
`X-Actions`, `X-Attach` and `X-Icon`, which can make the receiving phone
issue an arbitrary HTTP request, so a single attacker-controlled header
would turn it into a confused deputy inside your network.

**When no notification arrives.** Five things have to happen in order, and a
break in any of them looks identical from the phone - which is to say, like
nothing at all. Walk them from the inside out; each step tells you whether
the next one is worth checking.

1. **Is the session registered?** Inside the sandbox, `echo $DEJIMA_RUN_ID`
   and `echo $DEJIMA_NOTIFY_DIR`. Both empty means `dejima` started this
   container with remote access off - `[remote-access] enabled` was off at
   launch, and no later change affects a session already running.
2. **Is the hook registered?** The `Notification` and `Stop` entries live in
   the throwaway override layer, not in your real `settings.json`:
   `grep -c dejima-notify /etc/dejima-settings.json` from inside should be 2.
   That file is passed to the harness by `harness-wrapper.sh`, as whatever
   its manifest's `settings_args` names (`--settings` for Claude Code);
   if it is missing entirely, this container was not started by `dejima`.
3. **Does the marker reach the host?** This is the one to check first: it
   splits the chain cleanly in half. From inside the sandbox:

   ```sh
   : > "$DEJIMA_NOTIFY_DIR/waiting" && sleep 2 && ls "$DEJIMA_NOTIFY_DIR"
   ```

   The file vanishing means the host watcher is running and consuming, and
   everything below this line is host-side. The file remaining means
   `dejima-notify-watch` is not running - `systemctl --user status
   dejima-notify-watch`, and check `enable-linger` if it died with your
   session.
4. **Did the push succeed?** `curl`'s stderr goes to the watcher's journal:
   `journalctl --user -u dejima-notify-watch -n 50`. A `push failed` line
   with a 404 usually means `ntfy_url` names the server but no topic; a 401
   or 403 means the instance wants credentials, which the URL can carry as
   `https://<user>:<token>@<host>/<topic>` - nothing here sends an auth
   header of its own.
5. **Is the phone subscribed to the topic the config names?** Last in the
   list and first to check in practice, since it is the only link with no
   log anywhere. The topic in `ntfy_url` and the one in the app have to be
   the same string.

Note also that step 3 sends a real notification when the chain is healthy,
which makes it a test of the whole path rather than only of the watcher.
Repeat runs within `[remote-access] debounce` (60 by default) are consumed
without pushing, so leave a minute between attempts or you will diagnose the
debounce instead.

## Attaching

`dejima-attach` with no argument gives a numbered picker - digits rather
than arrow keys, because a phone soft keyboard handles those far better.
`--list` prints one tab-separated row per live session for scripting, and a
run-id argument attaches directly, which is what the deep link and `ttyd`'s
`--url-arg` produce. Rows carry the run id, the tmux label, the workspace
name, the session's age, its state, and the container id.

The picker is coloured (gruvbox) when stdout is a terminal that says it can
show it; `NO_COLOR=1` or a `dumb` `$TERM` turns that off, along with the
box-drawing glyphs. `--list` is never coloured, terminal or not - the picker
parses those rows itself and the README calls them scriptable.

Three states, from a registry `dejima` writes on launch and removes on
exit:

- `attachable` - a live tmux pane to join.
- `stale` - registered, but its pane is gone. Listed rather than hidden,
  since the registry is a hint and not truth: the exit trap doesn't run
  under `SIGKILL` or a host crash.
- `no-tmux` - the sandbox was started outside tmux, so there is no pane to
  attach to. Still listed, deliberately, rather than silently omitted.

Entries whose container has gone away are pruned as they're listed. When
Docker can't be asked at all, nothing is pruned and the container column
reads `?` - an unanswerable question is never treated as a "no".

Attaching creates a **grouped** tmux session (`dejima-<run-id>`) rather than
joining yours. Grouped sessions share windows but track their own current
window, so the phone can sit on one sandbox while the desktop sits on
another, and the throwaway carries `destroy-unattached`, so it disposes of
itself when the phone detaches or the connection drops.

**You get the whole window list, not just the one sandbox.** Sharing windows
is what "grouped" means: you land on the right window, and every other
window on your tmux server is one tab away - other sandboxes, and whatever
non-dejima windows you have open. Worth knowing before you first connect,
because it is a surprise otherwise.

It is not a containment boundary being crossed, which is why it is left as
it is. Whoever reaches this terminal is one prefix key away from a brand new
host shell no matter what the tab bar shows - that is the fact this entire
feature is designed around, and tmux offers no per-client way to take the
prefix away (key tables are server-global, so disabling it for the phone
would disable it for your desktop too). Restricting the view would be
tidier; it would not make a reachable front door any less of a host shell.
Authentication and the bind address are the controls that matter here.

Sizing is left to tmux on purpose: `dejima-attach` sets no `window-size`.
tmux's own default (`latest`, since 3.1) already keeps a small phone client
from shrinking the desktop's view, and the option's only scopes are the
window - which a grouped session *shares* with yours, so setting it there
would permanently overwrite your choice with nothing to restore afterwards -
and global. An operator who deliberately set `smallest` keeps it.
