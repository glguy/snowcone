# hub implementation notes

Running record of decisions, deviations from the design, fixes to ported
bugs, and open questions, in the order they were made. Section numbers here
("design 4.8") refer to the original phase-by-phase design, which
`docs/hub-design.md` has since replaced with a description of the result.

## Requirements from the user

- **No plugin compatibility** (decided with the user): ircc and dashboard
  plugins are ported to the hub api rather than shimmed. A plugin that
  returns a table, or fails on a `utils.*`/`components.*` module, is
  refused with a message saying to port it.
- **No filterdb for now** (ircc's `/upload_filterdb` with hsfilter). It is
  not a feature name in configuration and phase 5 doesn't port it.

- **Rolling buffers, not scrolling.** Every log-style view (status,
  console, cliconn, cliexit, bans, channels, and chat buffers to come)
  draws with `draw.draw_rotation`: new lines replace the oldest row above
  a moving divider, so lines stay put while updates roll in and can be read
  and clicked. Scrolling back pins the view (`vs.pin`). Keep this for every
  new view of a stream.

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
- **Module protocol.** A module may export `init_state`,
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
  subscriber errors after logging them, so the test exits nonzero.
  A failed *reload* still just returns `false, err`, so tests can check it.
- The `snowcone.setmodule` entry is installed once (`HUB.entry_installed`)
  and routes to `ui.entry`.

### Fields of HUB beyond the design's list

`boot` (first-load options: root, init path, ui, tick, strict, echo, args),
`dirty` (redraw needed), `entry_installed`, and `tty_suspended` (child
process holds the terminal; kept in HUB so a reload during `/edit`-like
commands doesn't lose count).

### State

- There are no state versions or migrations: six phases only ever added
  state, so `init_state` is the whole protocol.
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
  because snowcone otherwise exits 0 when nothing is pending.
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

- `subscribe` receives `sub` with `sub.on(topic, fn)`. The owner is
  filled in with the module name; plugins get `plugin:<name>`.
  Subscribers run in subscription order; nothing needed priorities.
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
- **DNS lookups and processes are cancelled with their task.**
  `snowcone.dnslookup` and `snowcone.execute` return handles (REVIEW.md
  F-070, F-071), which the task keeps as `t.lookup` and `t.process` and
  cancels when its wait ends. Cancelling an execute kills the child. A
  task whose child has the terminal sets `t.tty`, and `end_wait` gives the
  terminal back, so completion and cancellation share one path.
  `t:execute(command, args, input, opts)` passes `opts` (`group`,
  `max_output`) through. The `task.executed` route stays only for an
  execute started before a reload into this code.
- **Shutdown cancels every task** (`task.cancel_all`), after abandoning the
  networks and before closing resources, so a pending lookup or child can't
  keep the event loop running. Exiting cleanly is Lua's job: the C++ side
  has no fallback, and a client that is simply broken gets killed from
  outside (REVIEW.md F-052).
- **Signals quit.** The entry installs `snowcone.catch_signals(true)`, and
  `on_signal` (SIGINT, SIGTERM, SIGHUP) and the ^C key both run `app.quit`:
  the first starts quitting, with the UI still drawing so a slow network
  shows why, and the next shuts down at once. `shutdown()` restores the
  terminal and the default signal actions, so a further ^C ends a process
  that fails to exit. Nothing draws after shutdown (`dispatch.flush`), which
  would put the terminal back into curses mode. A ^C while a child has the
  terminal is left to the child (REVIEW.md F-060).
- **Pastes.** A paste goes into the editor up to its first newline. One over
  the native 64 KiB limit arrives as `on_paste(nil, size)` and is reported
  as an error; it was most likely pasted by mistake (REVIEW.md F-050).
- **`scrub` covers C1 controls too** (U+0080 to U+009F, replaced by
  U+FFFD), since some terminals obey them. It matters wherever text leaves
  curses, which draws controls visibly on its own: the iTerm2 notifier's OSC
  9 sequence, and `dispatch.report`'s stderr fallback (REVIEW.md F-019).
- **The UI is hub's to start.** snowcone has no script mode: a program has
  no terminal until it calls `snowcone.start_ui()`. hub's `init.lua` calls
  it only when run as the program, so tests (which pass options) stay
  headless, and the loader's `ncurses ~= nil` default still decides `ui`.

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

## Phase 4: dashboard features

### Golden fixtures

- `tests/hub/fixtures/snotes-live.log`: 666 notices captured from the live
  network for five minutes and anonymised by
  `tests/hub/tools/anonymize-snotes.lua`. Every nick, username, host,
  cloak, address (into 198.18.0.0/15 and 2001:db8::/32), gecos, account,
  oper name, channel, mask and non-server reason is replaced consistently,
  so bans still match the notices about them. Lines that don't re-parse to
  exactly the replaced fields are dropped, and no original value may
  survive. Override and bad-login notices carry unparsed personal text and
  are left out; the KILL path is replaced. The raw capture was deleted.
- `snotes-synthetic.log` covers every format by hand, including ones that
  didn't occur live and two lines that must not parse.
- `*.expected.lua` come from the dashboard's parser
  (`tests/hub/tools/expect-snotes.lua`); hub's copy of the parser matches it
  on every line. The parser is unchanged; a table-driven rewrite can now be
  checked against the fixtures.

### Features

- `features/common.lua`: `enabled(net, feature)` and per-network state in
  `state.features[feature][net]`, dropped on `net.removed`.
- snotice: stores per network (users, exits, klines, new_channels, load
  trackers, net_trackers, watches) as records; LoadAverage/LoadTracker are
  `lib/loadavg.lua`, NetTracker/MaskTracker `features/snotice/nettrack.lua`
  (binary prefixes stored hex-encoded). Watches emit `notify.alert` with a
  colour name instead of beeping. Users and exits fold keys with the
  network's casemapping. Connection entries now keep `class`, which the
  prefilter language could ask for but the dashboard never stored.
- `irc.oper` (protocol layer) fires once per connection: RPL_YOUREOPER, or
  user mode `o` (already opered, e.g. through a bouncer). Topology sends
  MAP and LINKS, snotice a TESTMASK per tracked range; RPL_YOUREOPER also
  sets `MODE <nick> +s <snomask>` (per network `snomask`, default
  `BFZbcklnsx`). Netsplits and netjoins resync the same way.
- The servers file (`servers_file`; the dashboard read `servers.lua` from
  the config directory by default, hub only when configured) is network
  configuration: `config.load` reads it into `cfg.servers`, a file that
  can't be read fails the load, and features read it with
  `common.servers(net)`. Topology used to own it, so oper's reasons and
  snotice's ranges needed the topology feature.
- topology: populations, links/upstream, versions, uptimes, drains,
  sheds, DNS rotations every 30 s (timer id kept in state so reloads don't
  add timers). **Fixed:** LINKS replies merge both directions; the
  dashboard replaced a server's set, so reply order could drop links.
- oper: staged K-Line/unkline/undline per network with TESTMASK counts,
  durations, reasons and tags (servers file plus `/tag`), freeze. Staging
  sends only queries; `commit` sends the ban, from the UI's buttons.
- Feature commands carry `feature`; they run and appear in help and
  completion only when the current network has it (Meta-A in help shows
  all).

### Views and commands

- cliconn, cliexit, connload, exitload, banload, spamload, bans, netcount,
  repeats and channels (the dashboard's new-channel list; ircc's /list view
  will need another id). Dashboard globals became view state: filter,
  prefilter, server_filter, conn_filter, mark_filter, highlight,
  show_reasons, ordering, descending, expanded. Esc clears the filters
  (each view's `reset`).
- The dashboard's `/filter` query language is `/prefilter` in hub, because
  `/filter` is the per-view pattern filter of every view (decided with the
  user: keep both names).
  `lib/matchdsl.lua` no longer needs rex_pcre2 to load; regex terms do.
- The action bar (reason/org/asn/ip, duration, trust, freeze, reason, tag,
  staged KLINE/UNKLINE/UNDLINE with TRACE) is `ui/dashboard.lua`, shared by
  cliconn, cliexit and bans.

### Checked by hand

Live against the soju bouncer: cliconn, connload with MAP populations, the
status-bar load graph. Side by side with `snowcone dashboard` on the same
network, the total population agreed to within 1-2 users over three
samples (the difference is sampling time).

## Phase 5: chat

- chat: buffers per network in `state.features.chat[net].buffers`, keyed by
  folded target, each `{name, messages = OrderedMap(1000), activity,
  mention}`, drawn as rolling buffers. A new buffer asks for its history
  (CHATHISTORY BEFORE the opening message, or LATEST); after registration
  every buffer asks again and private buffers are monitored. Membership
  events go to the channels they concern: QUIT and NICK carry
  `msg.channels`, which net/handlers fills before the model forgets.
  WALLOPS/OPERWALL go to `*wallops`. Our own PRIVMSG/NOTICE come back from
  `irc.sent` (no echo-message). Mention patterns: the network's `mention`,
  else the global one. CTCP replies only to requests from staff; VERSION
  is a fixed string (ircc ran `git rev-parse` through io.popen).
- `/talk`, `/list` emit `chat.focus` and `chat.show_list` for the UI. The
  `list` view has no `/list` command of its own (`command = false`), since
  the chat command already shows it.
- notify: backends bell, mac (terminal-notifier through a task) and iterm2,
  chosen by `[notifications] module` (ircc's `notification.mac` works).
  Muted entries and dismissal both use the folded target; ircc's dismiss
  looked up one key and cleared another. `register_backend` adds more.
  `notify.alert` beeps or flashes in the UI.
- UI: buffer view with a talk target per network (`vs.targets`), talk
  mode (`t`), Ctrl-N/P through buffers, Meta-A to the next buffer with
  activity (mentions first), Meta-S back to the previous one, Meta-H to
  hide joins, parts, quits and nick, account and host changes, completion
  of channels and of nicks in the talk channel. The status bar marks
  networks with unseen chat: `+`, or `!` for a mention.
- Crypto commands (`ecdsa_new`, `ecdsa_fp`, `x25519_new`, `cert_new`,
  `cert_fp`) print to the status log. **Fixed ircc bugs:** `x25519_new`
  called a missing `get_raw_private` (the raw key is `export().priv`), and
  an empty PEM password passed '' without a cipher, which myopenssl
  rejects, so unencrypted keys couldn't be made.
- `/dump` escapes `\` in tags (ircc mapped it to itself); `/sasl` retries
  authentication with a named credential.
- **Tests now draw the UI**: `tests/hub/fake_ncurses.lua` stands in for
  ncurses, and `test-views.lua` loads the whole UI generation, replays the
  notice fixtures and chat, draws every view (also scrolled back) and drives
  keys through the native entry point. It caught a `/list` command clash
  that the headless tests couldn't see.
- Checked by hand against the bouncer: four channel buffers from the
  bouncer's JOINs, `/talk` to a joined channel (history only, no JOIN),
  buffer view and status bar.

## Phase 6: plugins and polish

- `features/plugins`: one loader, one api (README "Hub" and the header of
  the module). Plugins start when their generation activates, after the
  previous generation's plugins are stopped, and register subscriptions,
  commands and views into it, so they reload with it. Starting them during
  the build ran their tasks before `HUB.current` existed on first boot. Registration errors (a command
  name a built-in already has) are the plugin's, logged, and the rest of
  the client loads. Handlers run under `xpcall`; errors are logged with the
  plugin's name and never stop other subscribers.
- Plugin resources and tasks are owned by `plugin:<name>`. The names
  started are kept in `HUB.plugins_started`, so the next generation closes
  them before starting its own, and timers, tasks and listeners don't
  outlive the code that set them. Timer and httpd callbacks
  go through a per-generation registry (`plugins.callback`); one that
  fires after a reload finds nothing and does nothing.
- `api.state` is `state.features.plugins[name]`, so it survives reloads
  (not restarts; there is no file like the old `.dat`).
- `/plugins` lists plugins with their error or the views they added.
- Watches in configuration: `[[networks.watches]]` with pattern, colour,
  beep, flash, active. Applied on every load: configured watches are
  replaced (hit counts kept by pattern), /addwatch ones stay.
- Topology sends MAP and LINKS when registration ends, as the dashboard
  did, so the server list doesn't wait for operator status; becoming an
  operator syncs again unless a sync happened in the last 10 s (a bouncer
  reports oper status right after registering). Every server in a MAP reply
  gets a row in connload/exitload, so all servers show without a servers
  file (the dashboard only listed servers from servers.lua or with traffic).
- `snowcone.monotime()` (client/applib.cpp): steady_clock seconds.
  `clock.now()` uses it when present, so system clock changes don't
  disturb timeouts and backoff; it is only for differences.
- README has a Hub section (config example and plugin example, both
  checked by loading them); the man page has a HUB section and the new
  files.

## Dashboard parity

Compared with the dashboard's code (commands, views, IRC handlers, keys):

- Done: the title turns red while a K-Line is staged on the current
  network (`statusbar.title_colour`); the console inspector shows a server
  notice's parsed fields, as the dashboard's did.
- Not ported, by decision: `/shed_eta` (user shedding may get a better
  design); Esc cancelling a staged ban (the CANCEL button does it).
- `/stats` (decided with the user) is for a developer working out what the
  client is doing and holding: memory with GC, uptime, generation and the
  last load's result, resources by kind and owner, error counts by origin,
  tasks with what each waits on and for how long, and entry counts of every
  store per network (used/capacity for rings). Counts only: Lua can't size
  a value, and shared messages would be counted twice. No CLEAR buttons.
- Three kinds of state, three places: the client (`/stats`), a network
  identity across connections, and one connection. `/session` is the
  network page, a Network section (configuration in effect, state,
  attempts, backoff, retry, features) above a Connection section (lag,
  idle, transport, nick, modes, caps, channels, tasks). Clicking a network
  in `/networks` opens it.
- Different by decision: `servers_file` must be configured, `/prefilter`,
  hub's own configuration and plugins. CTCP replies to staff belong to the
  chat feature, so a network without `chat` doesn't answer them.

## Review pass

A review of hub/ found ten issues; decisions with the user:

- Batches are handled as they arrive (a netsplit's QUITs update the model
  at once) and still emitted whole as `irc.batch`. A replay batch
  (`chathistory`, `draft/chathistory-targets`, and anything nested in one)
  never touches the connection's state: its lines reach only `irc.batch`,
  for chat buffers. ircc and the first port set every batched line aside.
- Chat history goes into a buffer before the messages received on the
  current connection, in the server's order, skipping lines it already has
  (by msgid, else time tag, source and text). Server times are never
  ordered: an earlier version sorted by them, mixed with our own clock.
  History used to land after the newer message that opened the buffer.
- "Is this our nick" uses the network's casemapping (`irc.is_me`).
- The editor accepts line breaks (^J, ^M, x0a): it also takes Lua for
  /eval. Hex input checks its digits; history compares lines in order (an
  anagram of the last line was being dropped). From ircc.
- A nick change onto a nick that already has a buffer renames nothing; the
  change is noted in the old buffer.
- An empty `kline_reasons` falls back to the default reason.
- Drains are no longer tracked (`/drains`, the drain marker, the netjoin
  check); to be revisited with user shedding.
- Not changed: interleaved ban-list replies share one collector; servers
  don't interleave them.
