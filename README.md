# Snowcone - solanum server notice console and chat client

Snowcone is a small core C++ project that provides the facilities
necessary for a highly configurable and robust IRC functionality.
Its behavior is programmable via the Lua scripting language. Two
Lua packages are provided enabling snowcone to be the premiere
solanum server notice console as well as a relaxed chat client.

To use snowcone, create a configuration file as described below
and invoke one of the two modes:

```sh
# These mode shortcuts (dashboard/ircc) work when snowcone is installed
# otherwise you'll need to provide a path to the appropriate init.lua

# Launch the dashboard
$ snowcone dashboard

# Launch the client
$ snowcone ircc
```

## Dependencies

These are the baseline dependencies

```sh
# Debian build dependencies
apt install cmake pkg-config liblua5.4-dev libidn-dev libssl-dev libncurses-dev libgeoip-dev lua-mmdb lua-penlight lua-rex-pcre2-dev
# Optional on x86_64
apt install libhyperscan-dev
# Optional on arm64
apt install libvectorscan-dev
# Optional for testing
apt install libgmock-dev libgtest-dev lua-check

# Homebrew
brew install cmake pkg-config lua luarocks libidn ncurses openssl pcre2
# Optional on x86_64
brew install hyperscan
# Optional on arm64
brew install vectorscan
# Lua run-time dependencies
luarocks install penlight mmdblua lrexlib-pcre2

# On ARM mac you'll need to specify where pcre2 is installed
luarocks install lrexlib-pcre2 PCRE2_DIR=/opt/homebrew/opt/pcre2
```

Snowcone can also make use of doxygen, luacheck, libhyperscan/libvectorscan.

## Building and running

```sh
cmake --preset arm-mac
cmake --build --preset arm-mac --target install
out/install/arm-mac/bin/snowcone dashboard
```

## Dashboard - Important commands and behaviors

### Important keyboard keys

* <kbd>/</kbd> - start typing a command
* <kbd>Ctrl</kbd><kbd>S</kbd> - start typing a search query (Lua pattern string)
* <kbd>Esc</kbd> - exit current input mode
* <kbd>Ctrl</kbd><kbd>N</kbd> - next view
* <kbd>Ctrl</kbd><kbd>P</kbd> - previous view
* <kbd>F1</kbd>-<kbd>F8</kbd> - jump to view

### Main commands

* `/console` - raw IRC message view
* `/help` - list of slash commands
* `/quit` - quit the IRC connection and exit the application
* `/quote` - enter a RAW IRC command (lots of stuff isn't implemented so you might use this more than usual)

### Extra commands

* `/status` - client log messages
* `/session` - state of the IRC connection
* `/stats` - internal information
* `/eval` - run some Lua code

## IRCC - Important commands and behaviors

### Important keyboard keys

* <kbd>/</kbd> - start typing a command
* <kbd>t</kbd> - start typing a chat message
* <kbd>Ctrl</kbd><kbd>S</kbd> - start typing a search query (Lua pattern string)
* <kbd>Esc</kbd> - exit current input mode

### Main commands

* `/console` - raw IRC message view
* `/help` - list of slash commands
* `/talk <target>` - open a chat buffer for a channel or PM
* `/close` - close the current chat buffer
* `/quit` - quit the IRC connection and exit the application
* `/quote` - enter a RAW IRC command (lots of stuff isn't implemented so you might use this more than usual)

### Extra commands

* `/status` - client log messages
* `/session` - state of the IRC connection
* `/stats` - internal information
* `/eval` - run some Lua code

## Configuration

Default configuration path in order of preference

* Argument to `--config` flag
* `$XDG_CONFIG_HOME/snowcone/settings.toml`
* `$HOME/.config/snowcone/settings.toml`

Configuration file format is selected by file extension:

* `.toml` - parsed as normal TOML
* `.lua` - Lua module is executed

```toml
[identity]
nick = 'snowcone'
user = 'myuser'
gecos = 'your realname text'

[server]
host = 'irc.libera.chat'
password = 'a server password'

# optional; enables TLS
[tls]
client_cert.file = '/path/to/pem' # optional; specify TLS client certificate
client_key.file = '/path/to/pem' # optional; special TLS client private key
verify_host = 'host.name' # optional; used to override expected hostname; set '' to disable verification

# optional; enables SASL
[sasl]
automatic = ['external', 'plain'] # Automatic SASL mechanisms in fallback order

# optional; adds a credential named plain
[sasl.credentials.plain]
mechanism = 'PLAIN'
username = 'username'
password = 'somepassword'

# optional; adds a credential named external
[sasl.credentials.external]
mechanism = 'EXTERNAL'

# optional; adds a highlight pattern
[mention]
patterns = [ # Lua's pattern match syntax
    '%f[%w]yournickname%f[^%w]',
]

[notification]
module = 'notification.mac' # works on macOS using terminal-notifier
# module = 'notification.bell' # uses normal terminal BELL character

# optional; configure your network operator credentials
[oper]
automatic = false
username = 'username'
password = 'password'

# optional; configure your network operator challenge key
[challenge]
username = 'username'
key.file = '/path/to/pem'
password = 'password' # optional; private key decryption password
```

Credentials can be specified as:

* Literal string: `"example"`
* File contents: `{file="path"}`
* Command stdout: `{command="executable", arguments={"arg1", "arg2"}, multiline=false}`

Lua module example

```lua
return {
    server = {
        host = 'irc.libera.chat'
    },
    identity = {
        nick = 'snowcone'
    }
}
```

## Dashboard Pre-filter

Viewed connections can be filtered with the `/filter <disjunct>` command.

Example: `/filter nick "glguy" and (host |\.com$|I or account "*")`

To reset the filter use an empty `/filter`

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

## Server-side spam filter configuration

Snowcone's ircc mode can load hyperscan databases for configuring the
server-side message filter extension. This requires installing either
the `hyperscan` or `vectorscan` optional packages.

Example `patterns.lua` can be loaded with `/upload_filterdb /path/to/patterns.lua`.

```lua
{
    patterns = {
        {
            actions = {'DROP', 'ALARM'},
            flags = {'HS_FLAG_SINGLEMATCH', 'HS_FLAG_CASELESS'},
            regexp = 'example spam string',
        },
        {
            actions = {'KILL'},
            flags = {'HS_FLAG_SINGLEMATCH'},
            regexp = 'example kill string',
        },
    },
}
```
