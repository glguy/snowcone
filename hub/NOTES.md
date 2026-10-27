# hub decisions

Decisions the code doesn't explain on its own, with their reasons, and
mistakes made once that must not be made again. `docs/hub-design.md`
describes how hub is built; this file doesn't repeat it. Add an entry when
a decision is made, and change or remove it when the decision does.

## Scope

- **hub replaces ircc and dashboard.** Lua-side fixes and features go into
  hub only. ircc and dashboard are only kept working when a native API
  they use changes.
- **No plugin compatibility.** ircc and dashboard plugins are ported to the
  hub api, not shimmed. A plugin that returns a table, or fails on a
  `utils.*`/`components.*` module, is refused with a message to port it.
- **No filterdb** (ircc's `/upload_filterdb` with hsfilter) for now.
- **Not ported from the dashboard:** `/shed_eta` and drain tracking (to be
  designed together with user shedding), and Esc cancelling a staged ban
  (the CANCEL button does it).
- **Different from the dashboard on purpose:** `servers_file` must be
  configured; the connection query language is `/prefilter`, because
  `/filter` is every view's pattern filter (both names kept); CTCP replies
  to staff belong to chat, so a network without `chat` doesn't answer them.

## Runtime

- **`init.lua` is a stub.** The client reports an error in the main file
  only by leaving curses mode, so nothing that can fail lives there: it
  loads `runtime/loader.lua` fresh and calls `loader.reload`. Its optional
  chunk argument is how tests boot hub headless.
- **Globals fail at load time.** Each generation's environment reads
  through to `_G` and raises on assignment, so an accidental global is
  caught without luacheck.
- **`ui/control.lua`** holds view selection, input mode and talk targets
  so key handlers, the command line and the renderer share them without a
  require cycle.
- **No state versions or migrations.** `init_state` only adds, and that
  has been enough. A change that must reshape existing state needs a
  decision first.
- **Functions stay out of state.** An OrderedMap's ticker predicate lives
  in a weak-keyed table in the module (the renderer sets it every frame),
  and the scroll pin lives in the view state, since two views of one map
  would fight over a pin kept in the map.
- **One draw per burst.** The screen is not redrawn per inbound message:
  code that changes what is shown calls `dispatch.dirty()`, and the
  connection defers drawing until the line that ends a read.
- **Strict mode** (tests) re-raises route and subscriber errors after
  logging them; a failed reload still returns `false, err` so tests can
  check it.
- **Tasks outlive their code.** A coroutine suspended under old code is
  resumed by whichever generation's task module gets its wakeup, so the
  record fields and resume values at the top of `runtime/task.lua` are a
  contract: keep them few and stable. `seq` changes with every wait so
  stale wakeups are ignored.
- **A task's lookup or child is cancelled with it**, and cancelling an
  execute kills the child. Completion and cancellation share `end_wait`,
  which also gives back the terminal.
- **Plugins start at activation, not during the build.** Starting them in
  the build ran their tasks before `HUB.current` existed on first boot. A
  new generation closes the old plugins' resources and tasks first, and
  plugin timer and httpd callbacks go through a per-generation registry,
  so one that fires after a reload does nothing.
- **Quitting.** The first quit (`/quit`, ^C, SIGINT, SIGTERM, SIGHUP) sends
  QUIT and keeps drawing, so a slow network shows why it is waiting; the
  next exits at once. Shutdown cancels every task after abandoning the
  networks and before closing resources, so no pending lookup or child
  keeps the event loop alive. Nothing draws after shutdown, which would put
  the terminal back into curses mode. A ^C while a child has the terminal
  is the child's. There is no fallback in C++: exiting cleanly is Lua's
  job, and a broken client is killed from outside.
- **Pastes** go into the editor up to the first newline. One over the
  native 64 KiB limit is reported as an error; it was most likely a
  mistake.
- **`scrub` replaces C1 controls too** (U+0080 to U+009F), which some
  terminals obey. It matters where text leaves curses: the iTerm2 OSC 9
  notification and the stderr fallback of `dispatch.report`.
- **Server times are never ordered or compared.** An earlier version
  sorted chat history by them, mixed with our own clock.
- **Tests** pass a configuration table (`{}` by default) so they never read
  the user's files, and have a watchdog because snowcone exits 0 when
  nothing is pending.

## Configuration

- **Clean break from ircc and dashboard files:** no single-server shape,
  no `settings.toml`. Old top-level keys are reported as unexpected. A
  `.lua` configuration runs in its own environment.
- **Loaded inside the guarded build**, so a bad file on reload leaves the
  old code and configuration running; it is committed, and its warnings
  logged, at activation.
- **Only values sent on an IRC line** (`server.password`, `oper.password`)
  reject CR, LF and NUL. Other secrets may be PEM text.
- `lib/schema.lua` keeps only the warnings of the oneOf alternative that
  matched, and raises errors without a source position.
- **The servers file is network configuration**, read with it; a file that
  can't be read fails the load. It used to belong to topology, which made
  oper's reasons and snotice's ranges depend on that feature.
- **Watches from configuration** are replaced on every load, keeping hit
  counts by pattern; watches added with `/addwatch` stay.

## Networks and protocol

- **The stale-event guard** needs the attempt to match *and* the record to
  still have a connection; otherwise an END from an attempt closed locally
  is handled twice.
- **Registration** sends `CAP LS 302`, PASS, NICK and USER together. A
  server without CAP sends 001 during LS, and ERR_UNKNOWNCOMMAND for CAP
  ends LS; ircc then waited for a second 001.
- `sasl` without a value in CAP LS means the mechanisms are unknown, so
  all are tried.
- **NAMES:** strip prefixes before matching the nick. ircc matched first
  and lost `@` from every entry.
- Handlers live in `handlers.commands`, apart from module exports, so a
  server command can't name a non-handler.
- **`draft/event-playback` is not requested by default:** playback should
  bring chat, not joins and parts. Add it per network with
  `server.capabilities`.
- **Batches** are handled as lines arrive, so a netsplit's QUITs update the
  model at once, and are still emitted whole. A replay batch
  (`chathistory`, `draft/chathistory-targets` and anything nested in one)
  never touches the connection's state; ircc and the first port set every
  batched line aside.
- **Chat history** goes before the messages of the current connection, in
  the server's order, skipping lines a buffer already has (by msgid, else
  time tag, source and text). It used to land after the message that
  opened the buffer.
- **"Is this our nick"** uses the network's casemapping.
- QUIT and NICK carry `msg.channels`, filled before the model forgets the
  user, so features can tell which channels they concern.
- Interleaved ban-list replies share one collector; servers don't
  interleave them.

## Features

- **snotice:** the parser is the dashboard's, unchanged, and matches it on
  every line of the golden fixtures; a table-driven rewrite must too.
  Fixtures never contain personal data: the live capture was anonymised
  consistently (so bans still match their notices), override and
  bad-login notices were left out because they carry unparsed personal
  text, and the raw capture was deleted. Connection entries keep `class`,
  which `/prefilter` can ask for.
- **Operator status:** `irc.oper` fires once per connection, from
  RPL_YOUREOPER or user mode `o`, since a bouncer session may already be
  opered. RPL_YOUREOPER also sets the network's `snomask`.
- **topology** sends MAP and LINKS when registration ends, so the server
  list doesn't wait for operator status, and again on becoming an operator
  unless it synced in the last 10 s (a bouncer reports oper status right
  after registering). LINKS replies merge both directions; the dashboard
  replaced a server's set, so reply order could drop links. Every server in
  a MAP reply gets a load row, servers file or not. The DNS rotation
  timer's id is kept in state so a reload doesn't add another.
- **oper:** staging sends only queries (TESTMASK); the ban goes out only
  from a confirming click.
- **chat:** our own messages come back through `irc.sent`, since
  echo-message isn't assumed. CTCP replies go only to staff, and VERSION
  is a fixed string (ircc ran `git rev-parse` through `io.popen`). A nick
  change onto a nick that already has a buffer renames nothing; the change
  is noted in the old buffer.
- **notify:** muting and dismissal both use the folded target; ircc's
  dismiss looked up one key and cleared another.
- **Crypto commands:** the raw x25519 key is `export().priv`, and an empty
  PEM password must not be passed as `''` without a cipher, which
  myopenssl rejects. ircc got both wrong.
- `/dump` escapes `\` in tags.

## User interface

- **Filters** are per view and use PCRE2 everywhere when `rex_pcre2` is
  installed, Lua patterns otherwise. ircc mixed the two.
- **Command errors** raised at level 0 (no source position) are the
  user's and log as one line; anything else gets a traceback.
- **Prompts** have their own editor, so a half-typed command survives and
  secrets never reach history. Esc aborts, and the task's secret fails.
- **The status view cuts lines at 400 bytes;** a longer line wrapped past
  the pad onto the rows below.
- **The editor** accepts line breaks (it also takes Lua for `/eval`), hex
  input checks its digits, and history compares lines in order (ircc
  dropped an anagram of the last line).
- **Status bar:** `modes` is only for what alters a view from its default;
  data such as loads and chat activity is `status`. A document's position
  shows only once it is scrolled, since the top is the default.
- **The title turns red** while a K-Line is staged on the current network,
  so it is hard to miss; it doesn't share the quiet style of the modes.
- **Closing the shown buffer** moves to one with a mention, else back to
  the previous one, else one with activity, else the next by name. The
  previous buffer beats plain activity so that closing a query visited
  with Meta-A returns to the channel you were in, rather than whichever
  busy channel comes first.
- The `list` view has no `/list` of its own (`command = false`): the chat
  command shows it.
- **`/stats`** is for working out what the client holds: counts only,
  never byte estimates (Lua can't size a value, and shared messages would
  be counted twice), and no CLEAR buttons.
