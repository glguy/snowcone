# Writing snowcone hub plugins

This document describes how to write a plugin for `snowcone hub`: how one is loaded, what it can do and what happens to it on a reload. The host is [hub/features/plugins/init.lua](../hub/features/plugins/init.lua). [plugins/github](../plugins/github) is a complete plugin to read alongside this.

Contents:

- [A first plugin](#a-first-plugin)
- [Loading and reloading](#loading-and-reloading)
- [Keeping data](#keeping-data)
- [Events](#events)
- [Commands](#commands)
- [Sending](#sending)
- [Views](#views)
- [The detail pane](#the-detail-pane)
- [Tasks](#tasks)
- [Timers](#timers)
- [HTTP listeners](#http-listeners)
- [Errors](#errors)
- [Beyond the api](#beyond-the-api)
- [Testing](#testing)

## A first plugin

A plugin is a Lua file that returns a function. hub calls that function with the plugin's `api`. This one remembers when each nick last spoke:

```lua
-- ~/.config/snowcone/plugins/seen.lua
local scrub = HUB.current.gen.require 'hub.lib.scrub'

return function(api)
    -- Kept across reloads in api.state, and across restarts in seen.dat
    api.state.seen = api.state.seen or api.load() or {}
    local seen = api.state.seen

    api.on('irc.message', function(ev)
        local msg = ev.msg
        if msg.command == 'PRIVMSG' and msg.nick then
            seen[msg.nick] = {at = os.time(), where = msg[1], net = ev.net}
        end
    end)

    api.command('seen', '$g', function(_, nick)
        local entry = seen[nick]
        if entry then
            api.log('%s spoke in %s on %s at %s', nick, entry.where, entry.net, os.date('%H:%M', entry.at))
        else
            api.log('%s has not been seen', nick)
        end
    end, 'Show when a nick last spoke', 'nick')

    api.view('seen', {
        render = function(_, win)
            for nick, entry in pairs(seen) do
                win:waddstr(scrub(nick .. ' in ' .. entry.where) .. '\n')
            end
        end,
    })

    api.task('save', function(t)
        while true do
            t:sleep((api.config.save_seconds or 60) * 1000)
            api.save(seen)
        end
    end)

    api.on('app.quit', function() api.save(seen) end)
end
```

Name it in the [configuration](CONFIG.md#plugins), then run `/reload`:

```toml
[plugins]
modules = ['seen']

[plugins.custom.seen]
save_seconds = 60
```

`/plugins` lists every configured plugin with buttons for the views it added, or says it failed. Click `[seen]` to open this one.

## Loading and reloading

`modules` lists the plugins to load, in order. Each name loads `<directory>/<name>.lua`. `api.name` is that name, and `api.config` is its `[plugins.custom.<name>]` table, or an empty table without one. The schema doesn't check `custom`, so the plugin must check its own settings, and raise an error from its start function if one is missing.

A plugin file runs again on every `/reload` and SIGUSR1, so a reload picks up edits to it. A reload goes in this order:

1. The new configuration and hub's own modules load. If any of that fails, the old generation keeps running and its plugins are never touched.
2. The new generation becomes current, and networks in the configuration are added, removed or updated.
3. The previous plugins' listeners and timers are closed and their tasks canceled, even for a plugin no longer listed.
4. Each listed plugin's file runs and its returned function is called, in order.
5. hub's modules activate, then `app.reloaded` is emitted with `{generation, first}`. `first` is true at startup.

What that means for a plugin:

- **Everything registered belongs to one generation.** Subscriptions, commands, views, timers, tasks and listeners all end at the next reload, and the plugin registers them again. It never needs to unregister anything.
- **Local variables start fresh** on each reload. Only [`api.state` and saved files](#keeping-data) carry over.
- **A plugin that fails to load stays stopped.** Step 3 has already happened by then, so a syntax error leaves no old copy running. The reload itself succeeds, `/plugins` says the plugin failed, and the error is in `/status`.
- **A listener can reopen its port,** because the old one is closed first.

A network may not be ready when a plugin starts. At startup the connection is just beginning, and even after a reload it may be down. Do work that needs a registered connection from `net.registered`, which also covers reconnecting. If it must also happen on a reload, try it from the start function too, and catch the failure:

```lua
api.on('net.registered', function(ev)
    if ev.net == net then join_channels() end
end)
pcall(join_channels)   -- on a reload, the connection is usually already up
```

## Keeping data

| Where | Survives | Holds |
|---|---|---|
| Local variables | until the next reload | Anything. |
| `api.state` | reloads, not restarts | Plain tables, strings, numbers and booleans: no functions, coroutines or handles. |
| `api.save`, `api.load` | restarts | A table of strings, booleans and finite numbers, and such tables. |
| `api.path(ext)` | restarts | Whatever the plugin writes itself. |

`api.state` is the plugin's part of `HUB.state`, and stays there if the plugin is removed from `modules` until the client exits.

`api.save(table)` writes the whole table to `<directory>/<name>.dat`, as readable Lua. It writes a new file and renames it over the old one, so a crash leaves one or the other. It raises an error for anything other than a table of those values, or if the file can't be written. `api.load()` returns what was last saved, or nil when there is no file, and raises an error if the file doesn't parse.

The file is created with ordinary permissions. Keep this in mind if a plugin saves secrets.

`api.path(ext)` returns `<directory>/<name>.<ext>`, for the plugin's own files. The file doesn't have to exist. The GitHub plugin reads `api.path 'events.txt'`.

## Events

`api.on(topic, fn)` calls `fn(ev)` for each event on a topic. [EVENTS.md](EVENTS.md) lists every topic and its payload. Events about a network carry `net`, so a plugin that works on one network should check it.

- Events are delivered synchronously, in order of subscription. Plugins subscribe after hub's own modules, so by the time a plugin hears an event, features have already handled it.
- A handler must not block, because the whole client waits for it. To wait for something, start a [task](#tasks).
- Payloads are live, shared with the rest of hub. Read them, and copy what you keep if it might change.

The message in `irc.message` has `command` (an integer for a numeric reply: `303`, not `'303'`), the arguments `msg[1]`, `msg[2]` and so on, `source`, `tags`, `time`, and, for a user's message, `nick`, `user` and `host`. The fields are listed in [hub/net/manager.lua](../hub/net/manager.lua). Replayed chat history isn't delivered as `irc.message`.

To act on messages only from people you trust, check something the server vouches for, such as a cloak in `msg.host`. Anyone on the network can choose their nick.

## Commands

```lua
api.command(name, spec, fn, help, usage, opts)
```

| Argument | Meaning |
|---|---|
| `name` | The command's name. A name already taken is reported as an error, and the command that has it stays. |
| `spec` | Its arguments, below. Required; use `''` for none. |
| `fn` | Called as `fn(ctx, ...)` with the parsed arguments. |
| `help` | The line in `/help`, where plugin commands are grouped by plugin. Default: `from plugin <name>`. |
| `usage` | The arguments as people read them, such as `'nick [count]'`. Default: worked out from `spec`. |
| `opts` | `{net = true}` makes it a [network command](#network-commands). |

A spec is words separated by spaces. The arguments must fit it entirely. A word that doesn't start with `$` is a literal that the user has to type and `fn` doesn't get. The rest each give `fn` one argument:

| Spec | Argument |
|---|---|
| `$g` | A word: anything up to a space. |
| `$p` | A path name, as a word. |
| `$v` | An identifier: ASCII letters, digits and `_`, not starting with a digit. |
| `$i` | An integer. |
| `$f` | A decimal number. |
| `$q` | A string in `'` or `"` quotes, without them. |
| `$r` | The rest of the line, not empty. Last only. |
| `$R` | The rest of the line, possibly empty. Last only. |

A line that doesn't fit logs `usage: /name <usage>` and `fn` isn't called. To report a problem from `fn`, raise an error without position information: `error('no such project', 0)`. See [Errors](#errors).

### Network commands

`ctx.net` is the network the command acts on, and `ctx.target` is the buffer shown for it, if any.

- With `{net = true}`, `/name@libera` runs it on `libera`, and otherwise it uses the current network. `ctx.net` is always an existing network: the command is refused when there is none.
- Without it, `/name@libera` is refused. `ctx.net` is the current network, or nil when there isn't one.

Use `{net = true}` for any command that sends. `api.networks()` returns the ids of all configured networks.

## Sending

```lua
api.send(net, 'PRIVMSG', '#channel', 'hello there')
```

The last argument may contain spaces; hub adds the `:`. Arguments can be strings or numbers. An argument written `{content = text, secret = true}` is sent as given and masked in the console and in `irc.sent`.

`api.send` raises an error when:

- the network has no connection,
- an argument contains CR, LF or NUL,
- an argument before the last is empty, starts with `:` or contains a space,
- the line is too long for the server.

A send can fail any time a network is down, so catch the error with `pcall` where that is expected, such as in a timer or a webhook handler.

An existing connection doesn't mean a registered one: during registration a send succeeds, and the server is likely to refuse the command. See [Loading and reloading](#loading-and-reloading). A network's `rate_limit` applies to plugins as well, so a line may wait its turn and is dropped if the connection ends first.

## Views

```lua
api.view('seen', {
    title = 'last seen',                -- default: the id
    render = function(ctx, win) ... end,
    keypress = function(ctx, key) ... end,
    status = function(ctx, win) ... end,
    modes = function(ctx) ... end,
})
```

| Field | Purpose |
|---|---|
| `render(ctx, win)` | Draws the view with `win:waddstr(text)` and the global `ncurses`. |
| `keypress(ctx, key)` | Optional. Returns true when it took the key. |
| `status(ctx, win)` | Optional status bar data. Calls `ctx.fragment(win)` before each fragment it adds. |
| `modes(ctx)` | Optional list of tags showing what alters the view from its default, each a string or `{tag, value}`. |
| `scope` | `'net'` for a view of the current network. Default: `'global'`. |
| `document` | True to draw the whole view into a pad and page it, rather than fill the screen. |

`ctx` has `id`, `net` (the current network), `rows`, `cols`, `vs` (the view's own state, which keeps its fields across reloads), and `add_button(win, text, action)` and `add_click(y, lo, hi, action)` for mouse regions, rebuilt every frame. A view with an id already in use is reported as an error and not added. The [design document](hub-design.md#7-user-interface) has more on views.

`key` is an integer: a code point, the negated byte for Meta (`-string.byte 'a'` is Meta-A), or a negated `ncurses.KEY_` value (`-ncurses.KEY_LEFT`). A view sees keys before the global key map, so return true only for keys it uses.

**Opening a view.** A plugin's view has no command of its own and isn't in the Ctrl-N/Ctrl-P rotation or on the function keys. It opens from its button in `/plugins`, or when the plugin calls `api.show_view(id)`, for instance from a command:

```lua
api.command('showseen', '', function()
    api.show_view 'seen'
end, 'Show the last seen view')
```

`api.show_view` takes any view's id, the plugin's or a built-in one, and raises an error for one that doesn't exist. Without a UI it does nothing.

**Drawing.** hub draws after something changes and once a second, and a plugin has no way to ask for a draw of its own, so a view may lag behind its data by up to a second. Render on every draw from data you already have, and never block.

Text from a server, a webhook or a file can hold control characters. Scrub it before drawing it, as `seen.lua` above does.

The global `ncurses` exists only with a terminal, so a plugin should touch it only from view functions.

## The detail pane

The detail pane shows one thing in full above the current view. `api.open_detail(kind, net, data)` replaces what it shows:

```lua
api.command('inspect', '', function()
    api.open_detail('value', nil, {code = 'seen', n = 1, seen})
end, 'Show everything seen, as a tree')
```

| Kind | `net` | `data` | Shows |
|---|---|---|---|
| `value` | nil | `{n = count, code = title, value1, value2, ...}`; `code` is optional | Lua values as a tree that opens with clicks, as `/eval` does. They are live, so the pane shows them as they are now. |
| `message` | The message's network | A message, such as `ev.msg` | An IRC message in full, as clicking one in a buffer does. |
| `channel` | The channel's network | `{name = '#channel'}` | A channel's information, as `/chaninfo` does. |
| `error` | nil | `{where = text, message = text, traceback = text}`; `traceback` is optional | An error and its traceback. |

The pane's other kinds exist for hub's own commands, and their data may change.

`api.open_detail` raises an error for an unknown kind, and does nothing without a UI. The data isn't checked when it's opened: a kind that can't draw what it was given is [disabled until the next reload](#errors), with the error in `/status` as `detail <kind>`.

Opening the pane emits no event and writes no log line, so only the pane holds `data`, until it shows something else. A reload keeps it open, so keep `data` to plain values that still make sense after one.

### Your own kinds

`api.detail(kind, record)` adds a kind, which then opens like any other:

```lua
api.detail('lastseen', {
    title = function(detail) return 'last seen ' .. scrub(detail.data.nick) end,
    render = function(ctx, win)
        local data = ctx.vs.data
        win:waddstr(scrub(data.nick .. ' spoke in ' .. data.where) .. '\n')
        ctx.add_button(win, '[forget]', function() seen[data.nick] = nil end)
    end,
})

api.command('lastseen', '$g', function(_, nick)
    local entry = seen[nick]
    if entry then
        api.open_detail('lastseen', entry.net, {nick = nick, where = entry.where})
    end
end, 'Show when a nick last spoke, in the detail pane', 'nick')
```

| Field | Purpose |
|---|---|
| `render(ctx, win)` | Draws the content. Rows wrap at the terminal's width, and the pane scrolls when they don't fit. |
| `title(detail)` | Optional text for the pane's rule. Default: the kind's name. |
| `keypress(ctx, key)` | Optional. Returns true when it took the key. It comes before the view's. |
| `modes(detail)` | Optional list of strings to show on the rule. |
| `wide` | True for rows that don't wrap; Left and Right scroll them. |

`ctx` is a [view's](#views), except that `vs` is the detail itself: `vs.data` and `vs.net` are what it was opened with, and it can keep its own fields. `detail` is the same record. Scrub text before drawing it, in `title` as well as `render`.

A kind belongs to one generation, like a view. It is added again on a reload, so an open pane stays open. If the plugin no longer adds it, the pane closes. A name already taken, by a built-in kind or another plugin, is reported as an error and the kind isn't added.

A kind whose `render`, `title` or `modes` raises an error is [disabled until the next reload](#errors), for every detail of that kind, with the error in `/status` as `plugin <name> detail <kind>`. So check data that may be missing or malformed.

## Tasks

A task is a coroutine that can wait without blocking the client. Use one for anything that spans time: a conversation with the server, a child process, a periodic job.

```lua
api.task(name, fn, ...)          -- fn(t, ...)
api.net_task(net, name, fn, ...) -- the same, on a network
```

Both run `fn` until its first wait and then return the task record. A task ends when `fn` returns, when you call `t:cancel()` or at the next reload. A task on a network also ends with that network's connection.

| Method | Waits for | Returns |
|---|---|---|
| `t:sleep(ms)` | A delay. | Nothing. |
| `t:wait_event(topic, predicate, timeout_ms)` | An event for which `predicate(ev)` is true; `predicate` and the timeout may be nil. | The event, or nil on timeout. |
| `t:dnslookup(name)` | A DNS lookup. | `nil, address...`, or an error. |
| `t:execute(command, args, input, opts)` | A child process. Pass a string as `input`, even `''`: without one, the child takes over the terminal. | `code, stdout, stderr`, or `nil, error`. |
| `t:prompt(label)` | The user to answer in the input line, for a secret. | The answer, or nil when aborted. |
| `t:wait_irc(commands, timeout_ms)` | A message on the task's network whose command is listed. | The message, or nil on timeout. |
| `t:request(commands, timeout_ms, cmd, ...)` | Replies to a command it sends. | An iterator over the replies. |
| `t:send(cmd, ...)` | Nothing; sends on the task's network. | Nothing. |
| `t:log(category, fmt, ...)` | Nothing; logs, tagged with the task's network. | Nothing. |

`wait_irc`, `request` and `send` need a network, so use them from `api.net_task`. In a task from `api.task`, `send` raises an error and `wait_irc` hears nothing.

Without `labeled-response` on the network, `t:request` iterates over `wait_irc` steps and only a timeout ends it, so the loop must `break` once it has its answer, and must check that each message is about its request:

```lua
api.command('ison', '$g', function(ctx, nick)
    api.net_task(ctx.net, 'ison', function(t)
        for msg in t:request({303}, 5000, 'ISON', nick) do
            api.log('online: %s', msg[2])
            break
        end
    end)
end, 'Ask whether a nick is online', 'nick', {net = true})
```

A canceled task stops at its current wait and doesn't run any more of `fn`, so save work before waiting if it has to survive a reload.

## Timers

```lua
local id = api.timer(ms, fn)
api.cancel_timer(id)
```

A timer fires once and is closed by the next reload. Canceling one that has fired does nothing. To repeat, start another from `fn`, or use a task that loops around `t:sleep`.

## HTTP listeners

```lua
api.httpd('::1', 8000, function(method, target, body, headers)
    if method == nil then
        api.log('http error: %s %s', target, body)   -- (nil, what, message)
        return
    end
    return 200, 'hello\n', {['Content-Type'] = 'text/plain'}
end)
```

The listener serves plain HTTP/1.1, and stays open until the next reload. Put a reverse proxy in front of it for TLS, as the [GitHub plugin](../plugins/github/README.md) does.

- **Request:** header names are lower case. A repeated header's values are joined with `, ` (`; ` for `cookie`).
- **Reply:** `status` is an integer from 200 to 999. `body` is a string. `headers` is a table of strings, without CR, LF or NUL. The server sets `Content-Length` and `Transfer-Encoding` itself.
- **No reply:** a handler that returns no status, raises an error or gives an invalid reply makes the client get a 500. An error is logged as the plugin's.
- **Failures:** a failure such as a port that can't be bound doesn't raise an error from `api.httpd`. It arrives as a call to the handler with `method` nil, whose results are ignored.

Handlers run on the client's main loop and must not block. Anything that can reach the port can call the handler, so check who is asking; the GitHub plugin verifies each request's signature.

## Errors

A plugin's errors stay with that plugin: the rest of the client and other plugins carry on. An error from its start function, a handler, a command, a view, a timer, a task or an HTTP handler goes to the status view, `/status`, like any other error in hub: category `error`, as `plugin <name> <where>: <message>`, and counted in `/stats`.

| Failure | Result |
|---|---|
| The file doesn't load, raises an error or returns something other than a function | The plugin doesn't start. `/plugins` says it failed. |
| The start function raises an error | `/plugins` says it failed, but what it registered before that stays active until the next reload. Check settings first. |
| A command or view name is taken | That one is reported and not added; the plugin keeps starting. |
| An event handler raises an error | Reported for that event; later events still call it. |
| A view's `render`, `status` or `modes` raises an error | Reported once. The view is disabled: it shows a line saying it failed until the next reload. |
| A detail kind's `render`, `title` or `modes` raises an error | Reported once. The kind is disabled the same way, for every detail of that kind. |
| A view's or kind's `keypress`, or a button's action, raises an error | Reported each time. The view or kind stays. |
| A task raises an error | Reported, and the task ends. |

Built-in views and kinds fail the same way, and `/reload` is how to try again after a failure of any kind: it keeps connections and scrollback, and restarts plugins. Click a line marked `▸` in `/status` for its traceback, and use `/filter plugin <name>` to see only one plugin's lines. The log holds a limited number of lines, so a failure from long ago can have rolled off; `/reload` repeats a load or start error.

`api.log(fmt, ...)` writes to the status view under the plugin's name; with only one argument, the text is used as it is.

## Beyond the api

Plugins are trusted code. They run in the client's process with its global environment: `HUB`, `snowcone`, `ncurses` (with a terminal), `myopenssl`, `mybase64`, `mytoml` and the rest, along with any Lua library `require` finds, such as Penlight. A plugin can assign globals, but those outlive reloads and can collide with other plugins, so keep to locals.

`require` in a plugin is the real one and can't see hub's modules. To reach one, use `HUB.current.gen.require 'hub.lib.scrub'` from the start function or file, or `t:api 'hub.lib.scrub'` in a task, and fetch it again after every reload (which happens by itself, as the file runs again).

Only `api` is meant for plugins. Everything else is hub's internals, and hub changes them, like the api itself, without keeping the old form working.

## Testing

Plugins run headless, without a terminal or a network, using the harness hub's own tests use: [tests/hub/test-plugins.lua](../tests/hub/test-plugins.lua) tests the api this way, and [tests/hub/test-github.lua](../tests/hub/test-github.lua) drives a whole plugin, with a fake transport playing the server, requests sent straight to its HTTP handler and commands through `T.command`. Plugins in this repository's `plugins/` directory are also checked by `luacheck`.
