# hub implementation notes

Running record of decisions, deviations from `docs/hub-design.md`, fixes to
ported bugs, and open questions. Newest phase last.

## Phase 0: skeleton

### Structure

- **init.lua is a stub.** The client reports an error while loading the
  main file by leaving curses mode and writing to stderr, so `init.lua` only
  loads `runtime/loader.lua` fresh and calls `loader.reload`. The procedure
  from design 5.5 lives there, and everything it calls runs under `xpcall`.
  `init.lua` takes an optional options table as its chunk argument, which is
  how tests boot hub headless (see `loader.reload` for the options).
- **app.lua** sits beside init.lua at layer 6. It lists the modules of a
  generation, wires them together (`build`) and runs activation. The loader
  gets the name `hub.app` from init.lua, so the runtime layer never names
  an upper-layer module.
- **Module protocol.** A module may export `init_state`, `migrate`,
  `routes`, `subscribe(sub)`, `commands`, `views` and `activate(first)`.
  Duplicate routes, commands or views fail the load.
- **Generation `require` via `_ENV`** (decided with the user). One
  environment per generation reads through to `_G`, and its `__newindex`
  raises, so an accidental global fails at load time as well as in
  luacheck. `hub.x.y` resolves to `x/y.lua`, then `x/y/init.lua`.
- **ui/control.lua** holds view selection and input mode. It is not in the
  design's file list; it exists so the key handlers, command line and
  renderer can share those functions without a require cycle.
- **irc_formatting moved from lib to ui.** It draws with ncurses, and only
  `ui` may touch ncurses.

### Routes and trampolines

- Every generation has a route table, `HUB.current.routes`. Trampolines
  carry only a route name and plain bound arguments. They call the
  `dispatch.enter` route, which looks up the target, runs it under
  `xpcall`, logs any error with its traceback, then draws if something
  marked the screen dirty.
- Lower layers reach upward through route names: `/quit` calls the
  `app.quit` route and `/reload` starts a 0 ms timer to `app.reload`.
- **Strict mode** (`strict = true`, used by tests) re-raises route and
  subscriber errors after logging them, so `snowcone script` exits nonzero.
  A failed *reload* still just returns `false, err`, so tests can check it.
- The `snowcone.setmodule` entry is installed once (`HUB.entry_installed`)
  and routes to `ui.entry`.

### Fields of HUB beyond the design's list

`boot` (first-load options: root, init path, ui, tick, strict, echo, args),
`dirty` (redraw needed), `entry_installed`, and `tty_suspended` (child
process holds the terminal; kept in HUB so a reload during `/edit`-like
commands doesn't lose count).

### State

- `state.VERSION` starts at 1; the design's example said 3. The version
  is written in `activate`, after the swap, so a failed load can rerun
  migrations.
- `clock.uptime()` is `now - state.clock.started`, not a counter.
- `state.log_last` is the status bar's copy of the last log line (`false`
  when dismissed).

### OrderedMap

- Record plus functions, with `kind = 'OrderedMap'`. A key-folding
  function became `casemapping`, a name resolved by `lib/casemap.lua`.
- The ticker predicate is a function, so it lives in a weak-keyed table in
  the module, not in the record. The renderer sets it every frame, so
  losing it on reload costs nothing.
- The scroll `pin` moved from the map to the view state, since two views of
  one map would otherwise fight over it.

### Timers

`runtime/timer.lua` timers are one-shot resources whose callback is a
trampoline. A fired timer releases its resource. Repeat by starting another
from the route (the 1 Hz tick does this).

### Tests

- `tests/hub/lib.lua`: assertions, `T.boot`/`T.reload`, and async cases
  with `T.sleep`. A watchdog fails the run if a case never finishes,
  because `snowcone script` otherwise exits 0 when nothing is pending.
- Reload tests 2 and 3 from design 5.7 are in `test-reload.lua`.
- `test-structure.lua` checks layering, native API ownership and
  EVENTS.md. For ncurses it flags field access (`ncurses.`), because the
  loader checks `ncurses ~= nil` to choose the headless default. lib
  modules may require other lib modules.

### Drawing (replaces `ui.invalidate`, agreed with the user)

The requirement is that the screen is not redrawn for every inbound message.
There is no `ui.invalidate` event. Code that changes what is shown calls
`dispatch.dirty()`, which sets `HUB.dirty`. At the end of each native
callback, `dispatch.enter` draws once if the screen is dirty, unless the
callback called `dispatch.defer_draw()`. The connection callback defers for
every `MSG` whose `flush` flag is false, so a burst of lines from one read
draws once, at the last line. A deferred change stays dirty and is drawn by
the next callback that doesn't defer (the flushing `MSG`, a key, or the
tick). Tested in `test-reload.lua`.

### Settled with the user

- `subscribe` receives `sub` with `sub.on(topic, fn, opts)`. The owner is
  filled in with the module name; plugins get `plugin:<name>`.
- With no configuration yet, the profile defaults to `all`.
- Tasks across reload (5.6): keep the handshake between a task record and
  the task module minimal. A coroutine suspended under old code is resumed
  by whichever generation's task module receives its timer or message, so
  the record fields and the yield/resume values must stay compatible across
  generations.
- Plugin callbacks: a per-generation registry keyed by id. Plugin timers
  that are still pending at a reload are dropped; reloads are infrequent.

## Phase 1: one network, headless

### Configuration

- **Clean break from ircc and dashboard configuration** (decided with the
  user): no legacy single-server shape and no `settings.toml` fallback.
  `runtime/config.lua` loads `--config`, else `hub.toml` or `hub.lua` from
  the config directory, applies `KEY.PATH=value` overrides, and validates
  against `runtime/config_schema.lua`. Connection settings exist only under
  `[[networks]]`; old top-level keys are reported as unexpected fields. A
  `.lua` config runs in its own environment, so its assignments don't
  become globals.
- Configuration is loaded inside the guarded build, so a bad file on
  reload leaves the old code and configuration active. It is committed to
  `state.config` in `activate`. Schema warnings (unexpected fields) are
  logged then.
- `features` is normalized to a set, `{snotice = true, ...}`, and unknown
  names are errors. Defaults: `autoconnect = true`, `reclaim_nick = true`,
  `reconnect = {min_delay = 1, max_delay = 300}`.
- New per-network keys: `reclaim_nick`, `snomask` (used in phase 4),
  `quit_message`.
- The dashboard's checks became schema patterns. Passwords sent on an IRC
  line (`server.password`, `oper.password`) reject CR, LF and NUL. Other
  secrets may be PEM text, so they don't.
- `lib/schema.lua` collects unexpected-field warnings instead of logging,
  and keeps only the warnings of the oneOf alternative that matched. It
  raises errors without a source position.
- Tests pass `config` as a table; `tests/hub/lib.lua` passes `{}` by
  default so tests never read the user's files.

### Tasks (`runtime/task.lua`)

- The handshake across reloads is the short list at the top of task.lua:
  record fields `id, name, owner, net, co, seq, wait, commands, timer` and
  the values each kind of wait resumes with. `seq` changes with every
  wait, so stale wakeups are ignored.
- Task methods are looked up through `HUB.current.task_methods` from a
  metatable that captures nothing. Bodies use `t:send`, `t:log`, `t:emit`
  and `t:api(name)` instead of module upvalues.
- `t:wait_irc(commands, timeout)` waits on the task's own network. The
  design's signature had a `net` argument, but every network task already
  has one.
- `t:prompt(label)` emits `task.prompt`; `task.answer(id, text)` replies.
  The UI side is phase 2.
- **DNS can't be cancelled.** `snowcone.dnslookup` returns its callback,
  not a handle (REVIEW.md F-070), and neither DNS nor `execute` can be
  cancelled natively (F-071). A cancelled task's late result finds no
  task, or a different `seq`, and is dropped. The design's native API
  table is wrong about `dnslookup` returning a handle with `cancel()`.
  ircc's committed fix in `Task:cancel_dnslookup` calls `h:cancel()` on a
  function, so it would raise.

### Network layer

- `state.nets[id]` follows design 6.1. Additions: `cfg` (the network's
  configuration table), `console` (OrderedMap of raw messages, both
  directions), `reconnect_timer`, `close_timer`, `registered_at`,
  `pinged`.
- The stale-event guard drops events unless `attempt` matches *and* the
  record still has a connection. Otherwise an END from an attempt that
  was already closed locally would be handled twice.
- Registration sends `CAP LS 302`, `PASS`, `NICK` and `USER` together and
  then reads LS replies. In ircc, a server without CAP support sent 001
  during LS and registration then waited for a second 001. ERR_UNKNOWNCOMMAND
  for CAP also ends LS.
- Nick reclaim uses MONITOR (ircc) and also fires on a QUIT of the wanted
  nick. The `net.reclaim_nick` route is there for the snotice feature to
  call on connect/nick notices (the dashboard's `target_nick`).
- `sasl` without a value in CAP LS now means "mechanisms unknown", so all
  are tried; ircc built a set from the empty string.
- **Ported bug fixed:** NAMES parsing matched `[^!@ ]+` before stripping
  prefixes, so `@` (op) was lost from every NAMES entry. Prefixes now come
  off first.
- Handlers live in `handlers.commands`, separate from module exports, so a
  server command can't name a non-handler.
- Liveness runs on `clock.tick`: PING after 30 s of silence when
  registered, close after 60 s; `connecting` times out after 60 s without
  CON. All compare `clock.now()` differences.
- Backoff: delay = backoff × (1 + 0–25 % jitter), then backoff doubles up
  to `max_delay`. A session registered for 60 s or more resets it first.
  Configuration errors (bad layer secrets, no host, bad connect arguments)
  set the target to idle instead of retrying; a refused or failed
  connection retries.
- Quit: QUIT on registered networks, immediate close for the rest, exit
  when every network is idle or after a grace period. A second `/quit`
  exits immediately. HUB gains `quitting`, `shut_down` and
  `task_next_id`.
- Removing a network from configuration disconnects it and drops the
  record after close. Feature state cleanup and the full diff table of
  design 4.8 are phase 3.

### UI

- The status view shows a log line's network id.
- It also cuts lines at 400 bytes. A line longer than the 550-column pad
  wrapped onto the rows below and left its tail there; ircc's renderer has
  the same problem.

## Phase 2: terminal UI for one network

- Views: `console` (raw traffic of the current network, from ircc),
  `status`, `stats`, `help` and `session`. Each view also gets a command
  of the same name. The first load opens the first view of the profile's
  rotation, which is `console` until the dashboard views exist.
- Console: clicking a command or `SNOW` inspects that message above the
  log, kept in the view's state as `focus`. Meta-H hides server notices
  and PING/PONG/AWAY; Meta-R shows inspected values raw. Server-notice
  decoding in the inspector waits for the phase 4 parser.
- Filters are per view (`vs.filter`). Ctrl-S edits one live, `/filter`
  sets one, Esc clears it. `lib/matching.lua` uses PCRE2 when `rex_pcre2`
  is installed and Lua patterns otherwise, for every view. (ircc's console
  used Lua patterns and its status view PCRE.)
- Password prompts: `task.prompt` events queue in `state.ui.input.prompts`.
  A prompt has its own editor (`input.secret`), so a half-typed command
  survives it and secrets never reach history. Enter answers, Esc aborts
  (the task's secret fails, as with a failing command). Prompts whose task
  ended are skipped.
- Commands: `connect`, `disconnect [message]`, `reconnect`, `quote`, `raw`
  and `nick` act on the current network, or on `@network` given first. The
  UI adds `filter`, `profile`, `net`, and the view commands. `ui.profile`
  from configuration applies when it changes; `/profile` overrides it until
  then.
- Command errors raised for the user (level 0, no source position) are
  logged as one line; errors with a position get a traceback. send's
  "not connected", "too long" and "prohibited character" are such user
  errors now.
- The status bar of a network view shows the network, and its phase when
  not connected.
- F1-F12 select the views of the rotation, as ircc's main views.

### Open

- `draft/event-playback` is no longer requested by default (decided with
  the user): playback should bring chat, not join/part noise. ircc listed
  it and only skipped it because soju announces it with CAP NEW during
  registration, which is ignored. Add it per network with
  `server.capabilities = ['draft/event-playback']`.
- Checked by hand against a soju bouncer: registration, live server
  notices in the console, /quote PING, filters, session/stats/help views,
  and a SIGUSR1 reload mid-session keeping the console, its filter and a
  half-typed command line.

## Phase 3: multiple networks

- Networks are ordered as in the configuration everywhere: the networks
  view, the status bar, Meta-1..9 and the default current network
  (`manager.ids()`). Records still closing after removal come last.
- Configuration reload follows design 4.8. A live network whose
  `server`, `layers`, `identity` or `sasl` changed keeps its connection
  and gets `restart_pending`; `/reconnect` (or any reconnect) uses the new
  settings. Everything else is read from `rec.cfg` when used, so it applies
  at once; the backoff is clamped to a new `reconnect` range. A removed
  network gets QUIT if registered and is dropped once closed, emitting
  `net.removed` for features to drop their state.
- Lag: the liveness check sends `PING <ms>` once a minute while connected
  (and after 30 s of silence, as before), one at a time; the matching PONG
  sets `rec.lag`. An unanswered PING stops counting after a minute.
- The all-networks console is its own ring, `state.console_all`, of
  `{net, msg, time, timestamp}` entries filled by `send.record` for both
  directions. Meta-G toggles it in the console view, with a network
  column; filters match the network id too.
- Status bar: every network, green when connected, red when idle, yellow
  in between, the current one in reverse video; click to switch.
- The networks view shows phase (with the target when it differs), time
  in phase, attempt, a countdown to a scheduled reconnect, lag, nick,
  transport and a restart-pending hint. It joined every profile's
  rotation.
- Checked by hand: two connections to the same soju bouncer plus an
  unreachable network; SIGUSR1 reload with all three; Meta-2 and the
  all-networks console; a configuration reload that removed a network and
  marked a gecos change pending, applied by `/reconnect @gl2`.
