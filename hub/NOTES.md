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

### Deviations to confirm

- `ui.invalidate` is not emitted. Marking dirty sets `HUB.dirty` and the
  draw happens at the end of the native callback. An event on every change
  seemed costly for no subscriber.
- `subscribe` receives `sub` with `sub.on(topic, fn, opts)`. The owner is
  filled in with the module name, rather than passed as in
  `bus.on(topic, owner, fn, opts)`.
- With no configuration yet, the profile defaults to `all`.

### Open questions for later phases

- Tasks across reload (5.6): a coroutine suspended in old code is resumed
  by whichever generation's task module handles its timer or message. The
  task record and the yield/resume protocol therefore need to stay
  compatible across generations; the plan is to keep that protocol tiny
  and versioned.
- Plugin closures (`api.timer(ms, fn)`) can't be bound as plain data. Plan:
  a per-generation registry of plugin callbacks keyed by id. Timers
  outliving a reload find no entry and are dropped, which matches plugins
  being reloaded with the generation.
