# hub design

`hub` is snowcone's third Lua application, beside `dashboard/` and `ircc/`.
It does the work of both — the solanum server-notice console with its ban
workflow, and a chat client — on any number of IRC networks at once, in one
process. This document describes how it is built and the rules that keep it
that way. It is for anyone changing hub, human or agent.

Related files:

- `hub/EVENTS.md` — every event topic and its payload.
- `hub/NOTES.md` — decisions and their reasons, in the order they were made.
- `README.md`, section "Hub" — user-facing configuration and plugin docs.

## 1. Principles

These hold everywhere. A change that breaks one needs a decision recorded in
`hub/NOTES.md` first.

1. **Strict layers.** A module may require its own layer or lower ones,
   never higher (section 2). Tests enforce it.
2. **No globals.** `HUB` is the only global hub creates. Modules run in an
   environment that raises on any other assignment.
3. **State is data.** Everything that must survive a reload lives in
   `HUB.state` as plain tables: no closures, coroutines or method-bearing
   metatables. Native handles live in `HUB.resources`.
4. **Native callbacks are trampolines.** A callback handed to C++ carries a
   route name and plain values, and finds its code in the current
   generation when it runs.
5. **Reload never drops anything.** SIGUSR1 or `/reload` swap in new code and
   configuration and keep connections, scrollback, stores, the line being
   typed and the screen position. A reload that fails leaves the old code
   running.
6. **Rolling buffers, not scrolling.** Every view of a stream draws new lines
   over the oldest ones, above a moving divider, so lines stay put while
   they are read or clicked. Scrolling back pins the view.
7. **Features never draw.** Features update data and emit events; the UI
   decides what to show, beep or flash.
8. **Failures stay where they happen.** An error in a route, subscriber,
   handler, plugin or command is logged with its origin and the rest of the
   client carries on.
9. **Everything below the UI runs headless.** The protocol and features run
   under `snowcone script` with a fake transport, so they are tested without
   a terminal or a network.
10. **Clean breaks over compatibility.** hub reads its own configuration
    format and its own plugin API. ircc and dashboard files are not read and
    their plugins are ported, not shimmed.

## 2. Layers

```
  6  app        init.lua, app.lua: generations, activation, quitting
  5  ui         terminal, views, input, key maps, command line
     commands   built-in commands (beside ui; bodies use lower layers only)
  4  features   snotice, topology, oper, chat, notify, plugins
  3  net        connection manager, protocol model, registration, CAP,
                SASL, send, batches
  2  runtime    loader, state, bus, dispatch, tasks, timers, resources,
                clock, config, secrets, log, tty
  1  lib        pure helpers: OrderedMap, casemap, schema, matching,
                matchdsl, loadavg, numerics, mkcommand, scrub
     native     snowcone.*, ncurses, myopenssl, mybase64, mytoml, ...
```

- `lib` requires nothing else from hub.
- Only `ui` touches `ncurses`. Only `net` calls `snowcone.connect`. Only
  `runtime` calls `newtimer`, `dnslookup`, `execute`, `setmodule`,
  `stop_input` and `start_input`; other layers use its wrappers, so every
  handle is tracked.
- A lower layer reaches upward only through a route name
  (`dispatch.route 'app.quit'`) or an event.

## 3. Runtime

### Generations and the loader

`hub/init.lua` is a stub that loads `runtime/loader.lua` fresh and calls
`loader.reload`. (The client reports an error in the main file by leaving
curses mode, so nothing that can fail lives there.) Each reload builds a
**generation**: a fresh module cache in which `require 'hub.x.y'` resolves to
`x/y.lua` or `x/y/init.lua`; other names go to the real `require`, so
Penlight and native libraries load once.

`app.build` loads configuration, every module and the plugins into the new
generation. Only when all of it succeeded does it become `HUB.current`;
`app.activate` then applies configuration and runs each module's
`activate`. Any error before the swap leaves the old generation current.

A module may export:

| Export | Purpose |
| --- | --- |
| `init_state(S)` | Create its part of `HUB.state` if missing. Runs on every load, so it is idempotent and only adds. |
| `migrate(S, from)` | Reshape old data when `state.VERSION` rises. Safe to run twice. |
| `routes` | `[name] = function`, targets for trampolines and late calls. |
| `subscribe(sub)` | `sub.on(topic, fn, opts)` on the generation's bus. |
| `commands` | `{name, spec, fn, help, scope, feature}` entries. |
| `views` | View records (section 7). |
| `activate(first)` | Runs once the generation is current. |

Duplicate routes, commands or views fail the build.

### The HUB root

| Field | Survives reload | Contents |
| --- | --- | --- |
| `state` | yes | All persistent data (below). |
| `resources` | yes | Native handles by id: `{kind, owner, handle, finalizer}`. |
| `tasks` | yes | Live tasks by id. |
| `current` | replaced | The generation: routes, bus, commands, views, config, module cache. |
| `boot` | yes | First-load options (ui, tick, strict, test transport...). |
| `generation` | yes | Count of successful loads. |

`HUB.state` holds `config` (the active configuration), `nets` (section 4),
`features[name][net]` (per-network feature state), `ui` (view states, input,
current network), `log`, `console_all` and `clock`.

### Routes, dispatch and drawing

Every native callback enters through `dispatch.enter(route, ...)`: the route
runs under `xpcall`, an error is logged with its traceback (and re-raised
only in the tests' strict mode), and the screen is drawn if something called
`dispatch.dirty()`. A callback that knows more is coming calls
`dispatch.defer_draw()`; the connection does that for every line but the
last of a read, so a burst of messages draws once. The 1 Hz tick draws
whatever is pending.

### Events

`bus.emit(topic, ev)` delivers synchronously, in priority order, each
subscriber under `xpcall`, then wakes tasks waiting on the event. Topics are
`area.event`; events about a network carry `net`. `hub/EVENTS.md` lists
every topic, and a test checks that every literal topic emitted is listed.

### Resources, timers and tasks

- `resources.add(kind, owner, handle, finalizer)` keeps a handle reachable
  (a collected timer never fires) and closable. Shutdown closes them all.
- `timer.start(owner, ms, route, ...)` is a one-shot timer firing into a
  route; repeat by starting another.
- `task.spawn(name, {net, owner}, fn, ...)` runs a coroutine that can
  `wait_irc(commands, timeout)`, `wait_event`, `sleep`, `dnslookup`,
  `execute` and `prompt`, and calls `t:send`, `t:log`, `t:emit`, `t:api`.
  A task scoped to a network is cancelled when its connection ends.
  A task keeps running the code it started with across a reload; the
  contract between a suspended task and the current task module is the
  short list of record fields and resume values at the top of
  `runtime/task.lua`. Keep it stable.

### Clock, configuration, secrets, log

- `clock.now()` is for durations (monotonic through `snowcone.monotime`).
  Compare by difference with `>=`. Times of day come from `os.date`.
- Configuration: `--config=PATH`, else `hub.toml` or `hub.lua` in the
  snowcone config directory, with `KEY.PATH=value` overrides; validated
  against `runtime/config_schema.lua`.
- Secrets — a string, `{file}`, `{command, arguments}` or `{prompt}` — are
  resolved inside tasks when needed and never stored in state.
- `log.add(category, ...)` and `log.add_net(net, category, ...)` feed the
  status view and the status bar.

## 4. Networks

`state.nets[id]` is one record per configured network; any number may be
connected at once.

- **Phases:** `idle`, `resolving_secrets`, `connecting`, `registering`,
  `connected`, `closing`; `target` is `connected`, `idle` or `removed`.
- **Attempts:** every connection attempt increments `attempt`, and its
  callbacks are bound to `(id, attempt)`. Events from an attempt that already
  ended are dropped.
- **Reconnecting:** exponential backoff with jitter within the network's
  `reconnect` range, reset after a session that lasted a minute. Errors in
  configuration (bad secrets, no host) stop retrying; refused connections
  retry.
- **Liveness:** a PING once a minute (and after 30 s of silence) measures
  lag; 60 s of silence closes the connection. All timeouts belong to Lua;
  the C++ side has none.
- **Registration:** `CAP LS 302`, PASS, NICK and USER go out together; SASL
  runs over the configured credentials in order until one succeeds; the
  welcome and the end of MOTD finish it. A rejected nick gets a temporary
  one, and the wanted nick is reclaimed through MONITOR or server notices.
- **Protocol model** (`rec.irc`): nick, modes, capabilities, ISUPPORT,
  channels and members, monitor list, batches. Keys fold with the network's
  CASEMAPPING, and so does "is this our nick".
- **Batches** are handled line by line as they arrive and emitted whole
  when they close. Replays (chat history) are the exception: they never
  change the connection's state and reach only the chat buffers, merged in
  time order. Handlers update only the model and emit events; everything
  user-facing is a feature.
- **Operator status** fires `irc.oper` once per connection, from
  RPL_YOUREOPER or a user mode `o` (a bouncer session that is already
  opered).
- **Sending** goes through `send.send(net, cmd, ...)`: arguments are checked,
  `{content, secret}` arguments are masked in logs, and every line, in or
  out, is recorded in the network's console and the all-networks console.

## 5. Features

A feature is enabled per network (`features` in its configuration; all by
default) and keeps per-network state in `state.features[name][net]`, created
on first use and dropped on `net.removed`. Feature commands carry `feature`
and only run, and only show, for networks that have it.

| Feature | What it does |
| --- | --- |
| snotice | Parses server notices (the dashboard's parser), keeps recent connections, exits, bans, new channels, per-second load trackers, address-range counts and watches; emits `snote` and `snote.<name>`. |
| topology | The network's servers file (regions, aliases, kline reasons and tags, address ranges), populations from MAP, links and upstream from LINKS, versions, uptimes, user shedding, DNS rotations. Asks for MAP and LINKS at registration, on becoming an operator and on netsplits and netjoins. |
| oper | Libera ban masks; staging a K-Line, unkline or undline with a TESTMASK count; sending it only on confirmation; operator commands. |
| chat | Buffers per network and target, routing, mentions, chat history, MONITOR, WALLOPS, CTCP replies to staff, `/list`. |
| bouncer | soju's bouncer-networks, shown in the bouncer view. |
| notify | Desktop or terminal notifications of mentions while the terminal is unfocused (always loaded; not per network). |
| plugins | Loads plugins into each generation (section 6). |

Features send only queries on their own (MAP, LINKS, TESTMASK, CHATHISTORY,
MONITOR, WHOIS, CTCP replies to staff). Anything with an effect — bans, joins,
messages — goes out only from a user action.

## 6. Plugins

A plugin is a Lua file in the plugins directory, listed in
`[plugins] modules`, that returns `function(api)`. The api is documented in
the README and at the top of `features/plugins/init.lua`: events, commands,
views, persistent `api.state`, sending, logging, tasks, timers and HTTP
listeners. Plugins load with each generation, into that generation, so they
reload with the client; their resources are closed once a newer generation
is current, and their callbacks fire only into their own generation. A
plugin's errors are logged under its name. Files written for ircc or the
dashboard are refused with a message to port them.

## 7. User interface

- **Views** are records `{id, title, scope, render(ctx, win),
  keypress(ctx, key), status(ctx, win)}`. `ctx` gives the view's persistent
  state (`ctx.vs`), the current network (`ctx.net`), the size, and
  `add_button`/`add_click` for mouse regions rebuilt each frame. Views read
  feature state and call feature functions; they don't send IRC or change
  stores themselves.
- **Streams** draw with `draw.draw_rotation` (principle 6).
- **Networks:** one is current (`/net`, Meta-1..9, clicking the status bar);
  net-scoped views and commands use it, and commands take `@network` first
  to use another. The status bar lists every network by state, with `+` or
  `!` for unseen chat.
- **Three scopes of state, three pages:** `/stats` is the client (memory,
  tasks, resources, errors, and entry counts of every store: summary
  counts, never byte estimates); `/session` is a network, what lasts across
  connections above the current connection; `/networks` is the overview.
- **Status bar fragments** are divided by one separator, the Powerline
  right-pointing triangle (U+E0B0, `statusbar.separator`). A view's
  `status` function starts each fragment it adds with `ctx.fragment(win)`.
- **Input modes:** command, filter (live, per view), talk, and password —
  prompts from tasks, with their own editor so a half-typed command
  survives and secrets stay out of history.
- **Profiles** (`[ui] profile`, `/profile`) choose the view rotation for
  Ctrl-N/Ctrl-P and the function keys: `dashboard`, `chat` or `all`.
- **Filters:** `/filter` and Ctrl-S filter any view by pattern (PCRE2 when
  rex_pcre2 is installed). The connection views also take a structured
  query with `/prefilter`.

## 8. Configuration

```toml
[ui]
profile = 'all'

[mention]                      # default for networks without their own
patterns = ['%f[%w]mynick%f[^%w]']

[notifications]
module = 'mac'                 # bell, mac or iterm2

[plugins]
directory = 'plugins'          # default; relative to the config directory
modules = ['example']

[[networks]]
id = 'libera'                  # default: the host
features = ['snotice', 'oper', 'topology', 'chat', 'bouncer']
autoconnect = true
reconnect = { min_delay = 1, max_delay = 300 }
reclaim_nick = true
snomask = '+BFZbcklnsx'
servers_file = 'servers.lua'
quit_message = 'bye'
[networks.server]              # host, port, fingerprint, capabilities, username, password
[[networks.layers]]            # tls, socks or http
[networks.identity]            # nick, user, gecos
[networks.sasl]                # automatic, credentials
[networks.oper]                # or [networks.challenge]
[[networks.watches]]           # pattern, colour, beep, flash, active
```

On reload the new configuration is validated before anything changes, then
applied per network:

| Change | Effect |
| --- | --- |
| New network | Added, and connected if `autoconnect`. |
| Removed network | QUIT, closed, record and feature state dropped. |
| `server`, `layers`, `identity`, `sasl` | Kept for the live connection, marked `restart_pending`; `/reconnect` applies them. |
| Anything else | Applies at once. |

## 9. Native API

hub relies on these parts of the `snowcone` table (see `client/`):

| Function | Contract |
| --- | --- |
| `connect(host, port, layers, cb)` | Handle with `send` and `close`; `cb` gets `CON`, then `MSG` (message, flush), then `END`. Bad layers raise. Dropping the handle doesn't end the session. |
| `newtimer()` | `start(ms, fn)`, `cancel()`; a collected timer never fires. |
| `dnslookup(name, fn)` | `fn(err)` or `fn(nil, addr...)`. Returns a handle whose `cancel()` keeps `fn` from running; dropping the handle doesn't cancel. |
| `execute(cmd, args, fn, opts?)` | `fn(code, stdout, stderr)` or `fn(nil, err)`. Options: `input` (without it the child has the terminal), `group` (own process group, needs `input`), `max_output` (per stream, 16 MiB default; past it the child is killed). Returns a handle whose `cancel()` kills the child (or its group) and keeps `fn` from running; dropping the handle doesn't cancel. |
| `time()`, `monotime()` | Wall clock (seconds, nanoseconds); monotonic seconds. |
| `setmodule(fn)` | The single entry for keyboard, paste, mouse, resize and print. |
| `start_httpd`, `parse_irc`, `parse_irc_tags`, `irccase`, `pton`, `shutdown`, `raise`, `isalnum`, `stop_input`, `start_input` | As documented in `client/`. |

Optional libraries (`mystringprep`, `hsfilter`, `myarchive`, `mygeoip`,
`mmdb`, `rex_pcre2`) are detected, never assumed.

## 10. Testing

All tests run under `snowcone script` from CTest, with `luacheck` over
`hub/`.

- `tests/hub/lib.lua`: assertions, `T.boot`/`T.reload` (headless, strict,
  with an empty configuration unless given one), asynchronous cases with
  `T.sleep`, and a watchdog that fails a case that never finishes.
- `fake_transport.lua` stands in for `snowcone.connect`; tests play the
  server line by line.
- `fake_ncurses.lua` lets the whole UI load and draw, so `test-views.lua`
  renders every view after replaying real traffic and drives keys through
  the native entry point.
- Golden replay: `fixtures/snotes-live.log` (captured from a live network,
  anonymised by `tools/anonymize-snotes.lua`) and `snotes-synthetic.log`,
  checked against the dashboard parser's output. Fixtures never contain
  personal data.
- `test-structure.lua` enforces layering, native API ownership and the
  event catalogue.

## 11. Direction

Open decisions:

- Whether hub replaces `ircc` and `dashboard` once it covers their use, and
  when they stop being installed.

Work that the design leaves room for:

- **Bouncer networks as hub networks:** soju BOUNCER BIND, with a network
  record pointing at its parent connection.
- **Drains and user shedding,** designed together (drains aren't tracked
  for now).
- **A table-driven notice parser,** checked against the golden fixtures.
- **Paging back through chat history** with CHATHISTORY BEFORE when a
  buffer is scrolled to its start.
- **State across restarts** (buffers, watches, plugin state) by saving
  `HUB.state` parts on quit.
- **More plugins ported** from ircc and the dashboard as they are needed.
