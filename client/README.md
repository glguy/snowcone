# snowcone ircc

Snowcone's **ircc** is a rewrite of the original snowcone aiming to build up
standard client functionality in addition to being a base on which to host
all of the previous IRC operator-focused status console information. At the
time of writing this document, the IRC operator status views have not been
ported over.

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

If you more control you can do a manual cmake build:

```sh
cmake -B build
cmake --build build
build/client/ircc luaclient/init.lua
```

## Important commands and behaviors

### Important keyboard keys

* <kbd>/</kbd> - start typing a command
* <kbd>t</kbd> - start typing a chat message
* <kbd>Ctrl-S</kbd> - start typing a search query (Lua pattern string)
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

    oper_username = 'username', -- used with OPER and CHALLENGE commands
    oper_password = 'password', -- used with OPER command
    challenge_key = '/path/to/pem', -- used with CHALLENGE command
    challenge_password = 'password', -- decryption password for challenge pem

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

    capabilities = { -- there are currently no default caps (sasl is automatic)
        'account-notify',
        'account-tag',
        'away-notify',
        'batch',
        'cap-notify',
        'chghost',
        'draft/chathistory',
        'draft/event-playback',
        'extended-join',
        'invite-notify',
        'multi-prefix',
        'server-time',
        'setname',
        'soju.im/bouncer-networks',
        'soju.im/bouncer-networks-notify',
        'soju.im/no-implicit-names',
        'solanum.chat/identify-msg',
        'solanum.chat/oper',
        'solanum.chat/realhost',
    },
}
```
