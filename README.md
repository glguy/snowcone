# Snowcone - solanum server notice console and chat client

Snowcone is a small core C++ project that provides the facilities
necessary for a highly configurable and robust IRC functionality.
Its behavior is programmable via the Lua scripting language. Its Lua
application, hub, makes snowcone the premiere solanum server notice
console as well as a relaxed chat client, on any number of networks.

To use snowcone, create a configuration file as described below
and run hub:

```sh
# The hub shortcut works when snowcone is installed; otherwise
# give the path to hub/init.lua
$ snowcone hub
```

## Dependencies

These are the baseline dependencies

```sh
# Debian build dependencies
apt install cmake pkg-config liblua5.4-dev libidn-dev libssl-dev libncurses-dev libgeoip-dev lua-mmdb lua-penlight lua-rex-pcre2-dev
# Optional for testing
apt install libgmock-dev libgtest-dev libvterm-dev lua-check

# Homebrew
brew install cmake pkg-config lua luarocks libidn ncurses openssl pcre2
# Optional for testing
brew install googletest libvterm luacheck
# Lua run-time dependencies
luarocks install penlight mmdblua lrexlib-pcre2

# On ARM mac you'll need to specify where pcre2 is installed
luarocks install lrexlib-pcre2 PCRE2_DIR=/opt/homebrew/opt/pcre2
```

Snowcone can also make use of doxygen and luacheck.

## Building and running

```sh
cmake --preset arm-mac
cmake --build --preset arm-mac --target install
out/install/arm-mac/bin/snowcone hub
```

## Hub - dashboard and chat on many networks

`snowcone hub` is a server notice dashboard and chat client, and connects
to any number of networks at once. It reads `~/.config/snowcone/hub.toml`
(or `hub.lua`, or `--config=PATH`); every connection setting lives in a
`[[networks]]` table. [docs/CONFIG.md](docs/CONFIG.md) describes every
setting.

```toml
[ui]
profile = 'all'            # view rotation: 'dashboard', 'chat' or 'all'

[mention]
patterns = ['%f[%w]mynick%f[^%w]']

[[networks]]
id = 'libera'
features = ['snotice', 'oper', 'topology', 'chat']  # default: all
servers_file = 'servers.lua'          # regions, aliases, kline reasons
reconnect = { min_delay = 1, max_delay = 300 }
rate_limit = { burst = 5, interval = 2 }  # optional; unlimited without it
snomask = '+BFZbcklnsx'               # set after opering
[networks.server]
host = 'irc.libera.chat'
port = 6697
[[networks.layers]]
type = 'tls'
[networks.identity]
nick = 'mynick'
[networks.sasl]
automatic = ['PLAIN']
[[networks.sasl.credentials]]
mechanism = 'PLAIN'
username = 'mynick'
password = { command = 'pass', arguments = ['show', 'libera'] }
[[networks.watches]]
pattern = 'badbot'
color = 'red'
beep = true

[[networks]]
id = 'oftc'
features = ['chat']
[networks.server]
host = 'irc.oftc.net'
port = 6697
[[networks.layers]]
type = 'tls'
[networks.identity]
nick = 'mynick'
```

Secrets (passwords, keys) can be a string, `{ file = 'path' }`,
`{ command = 'program', arguments = [...] }` or `{ prompt = 'label' }`.

Some things to know:

- The status bar lists every network, colored by state, with `+` or `!`
  for unseen chat; click one, use Meta-1..9, or `/net <id>` to choose the
  current network. `/networks` shows them all.
- Commands that act on a network can name one after the command:
  `/quote@oftc WHOIS someone`. `/quote` sends tags as typed:
  `/quote @+draft/react=👍;+draft/reply=abc TAGMSG #chan`.
- Every scrolling list is a rolling buffer: new lines replace the oldest
  above the divider, so nothing moves under the mouse.
- The console's Meta-G shows all networks interleaved.
- `/filter` filters the current view by pattern; the connection views
  also take a query with `/prefilter` (below).
- `/reload` and SIGUSR1 load new code and configuration and keep
  connections, scrollback and the line being typed; changed connection
  settings wait for `/reconnect`.

Plugins are Lua files in `~/.config/snowcone/plugins/`, listed in
`[plugins] modules`. A plugin returns a function that receives an api.

```lua
-- ~/.config/snowcone/plugins/hello.lua
return function(api)
    api.state.count = api.state.count or 0     -- kept across reloads

    api.on('snote.connect', function(ev)        -- any event; see hub/EVENTS.md
        api.state.count = api.state.count + 1
    end)

    api.command('hello', '$g', function(ctx, who)
        api.send(ctx.net, 'PRIVMSG', who, 'hello!')
    end, 'Say hello')

    api.view('hello', {
        render = function(ctx, win)
            win:waddstr(api.state.count .. ' connections seen\n')
        end,
    })
end
```

The api also has `api.log`, `api.task`, `api.timer`, `api.httpd`,
`api.networks()` and `api.config` (the `[plugins.custom.<name>]` table).
`/plugins` lists loaded plugins and their errors.

## Pre-filter

The connection views can be filtered with the `/prefilter <disjunct>` command.

Example: `/prefilter nick "glguy" and (host |\.com$|I or account "*")`

To reset the filter use an empty `/prefilter`

```
disjunct := conjunct ('or' disjunct)*

conjunct := atom ('and' conjunct)*

atom     := '(' disjunct ')'
          | 'not' atom
          | field pattern

field    := 'account'                   # e.g. "acct", unknown is "*"
          | 'asn'                       # e.g. "1234"
          | 'class'                     # e.g. "users"
          | 'gecos'                     # e.g. "realname"
          | 'host'                      # e.g. "example.com"
          | 'ip'                        # e.g. "192.0.2.0"
          | 'mask'                      # e.g. "nick!user@host"
          | 'nick'                      # e.g. "nick"
          | 'org'                       # e.g. "SOME-CORP"
          | 'reason'                    # e.g. "Client Quit"
          | 'server'                    # e.g. "gold.libera.chat"
          | 'user'                      # e.g. "user", unknown is "?"

pattern  := '|' regular-expression '|'  # pcre regexp
          | '|' regular-expression '|I' # caseless pcre regexp
          | '"' literal string '"'      # exact match
          | "'" literal string "'"      # exact match

```
