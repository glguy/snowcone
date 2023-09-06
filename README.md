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
apt install cmake pkg-config liblua5.4-dev libboost-dev libidn-dev libssl-dev libncurses-dev libgeoip-dev lua-mmdb lua-penlight
# Optional on x86_64
apt install libhyperscan-dev
# Optional on arm64
apt install libvectorscan-dev
# Optional for testing
apt install libgmock-dev libgtest-dev lua-check

# Homebrew
brew install cmake pkg-config lua luarocks boost libidn ncurses openssl
# Optional on x86_64
brew install hyperscan
# Optional on arm64
brew install vectorscan
# Lua run-time dependencies
luarocks install penlight mmdblua
```

Snowcone can also make use of doxygen, luacheck, libhyperscan/libvectorscan.

## Building and running

I have presets `intel-mac`, `arm-mac`, `debian-gcc` CMake presets that set
up the needed environment variables (see CMakePresets.json). Note that Debian's
`gcc-12` and `boost` packages are currently incompatible, so you have to
install `gcc-11` there.

```sh
cmake --preset arm-mac
cmake --build --preset arm-mac
out/build/intel-mac/arm-mac/ircc luaclient/init.lua
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
* `$XDG_CONFIG_HOME/snowcone/settings.lua`
* `$HOME/.config/snowcone/settings.lua`

Configuration file format is a Lua literal. All fields are optional
except: `nick`, `host`, `port`.

```lua
{
    -- the 3 required things
    nick = 'snowconer',
    host = "irc.libera.chat",
    port = "6697",

    user = 'myuser',
    gecos = 'your realname text',
    pass = 'a server password',

    tls = true, -- set to false for plaintext connections
    tls_client_cert = '/path/to/pem', -- optional
    tls_client_key = '/path/to/pem', -- defaults to tls_client_cert
    tls_client_password = 'apassword', -- defaults to '' if unspecified

    tls_verify_host = 'host.name', -- used to override the hostname in the host key
    -- most useful when connecting by IP address to a server with a certificate

    sasl_credentials = {
        default = { -- default is what get used at connection time automatically
            mechanism = 'PLAIN',
            username = 'username',
            password = 'somepassword',
        },

        use_cert = { -- other names can be invoked with: /sasl <credential name>
            mechanism = 'EXTERNAL',
        }
    },

    mention_patterns = { -- Lua's pattern match syntax
        '%f[%w]yournickname%f[^%w]',
    },

    notification_module = 'notification.mac', -- works on macOS using terminal-notifier
    -- notification_module = 'notification.bell', -- uses normal terminal BELL character

    plugin_dir = '/path/to/plugins',
    plugins = {}, -- list of plugin names

    -- Don't set these unless you run your own network
    oper_username = 'username', -- used with OPER and CHALLENGE commands
    oper_password = 'password', -- used with OPER command
    challenge_key = '/path/to/pem', -- used with CHALLENGE command
    challenge_password = 'password', -- decryption password for challenge pem
}
```
