# Configuring snowcone hub

This document describes the configuration file of `snowcone hub`: where it lives, what goes in it and what each setting does. Every connection setting lives in a `[[networks]]` table. The schema is [hub/runtime/config_schema.lua](../hub/runtime/config_schema.lua).

Contents:

- [The file](#the-file)
- [A complete example](#a-complete-example)
- [Top-level tables](#top-level-tables): `ui`, `mention`, `notifications`, `plugins`
- [Networks](#networks)
  - [Network settings](#network-settings)
  - [Features](#features)
  - [Connecting](#connecting): `server`, `layers` (TLS, SOCKS5, HTTP CONNECT)
  - [Registering](#registering): `identity`, server password, capabilities
  - [SASL](#sasl)
  - [Becoming an operator](#becoming-an-operator): `oper`, `challenge`
  - [Mentions and watches](#mentions-and-watches)
  - [The servers file](#the-servers-file)
- [Secrets](#secrets)
- [Reloading](#reloading)

## The file

hub reads the first file that exists of:

1. the file named with `--config=PATH`,
2. `$XDG_CONFIG_HOME/snowcone/hub.toml` (by default `~/.config/snowcone/hub.toml`),
3. `$XDG_CONFIG_HOME/snowcone/hub.lua`, a Lua chunk that returns the same structure as a table.

This directory is the *configuration directory*. Relative paths in the configuration, such as `servers_file`, `plugins.directory` and `{file = ...}` secrets, are relative to it.

Settings can be overridden on the command line with `key.path=value`, for example `ui.profile=chat`. Overrides are applied to the file's contents before checking.

A field of the wrong type, a missing required field or an unknown feature name stops the load with an error naming the field. A field the schema doesn't know is reported as `Unexpected field ...` in the status log and otherwise ignored, so check the log after editing.

## A complete example

```toml
[ui]
profile = 'all'

[mention]
patterns = ['%f[%w]mynick%f[^%w]']

[notifications]
module = 'mac'

[plugins]
modules = ['hello']

[[networks]]
id = 'libera'
servers_file = 'servers.lua'
snomask = '+BFZbcklnsx'

[networks.server]
host = 'irc.libera.chat'
port = 6697

[[networks.layers]]
type = 'tls'

[networks.identity]
nick = 'mynick'
gecos = 'My Name'

[networks.sasl]
automatic = ['PLAIN']

[[networks.sasl.credentials]]
mechanism = 'PLAIN'
username = 'mynick'
password = { command = 'pass', arguments = ['show', 'libera'] }

[networks.challenge]
automatic = true
username = 'mynick'
key.file = 'libera-challenge.pem'
password.prompt = 'challenge key password'

[[networks.watches]]
pattern = 'badbot'
colour = 'red'
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

In TOML, `[networks.server]` and `[[networks.layers]]` belong to the most recent `[[networks]]` entry above them.

## Top-level tables

### `[ui]`

| Field | Default | Meaning |
|---|---|---|
| `profile` | `'all'` | The view rotation for Ctrl-N/Ctrl-P: `'dashboard'`, `'chat'` or `'all'`. `/profile` changes it until the configured value next changes. |

### `[mention]`

| Field | Meaning |
|---|---|
| `patterns` | Lua patterns. A channel message matching any of them is a mention: its buffer is marked `!` and a notification may be sent. A private message is always a mention. |

A network's own `[networks.mention]` replaces these for that network. It does not add to them.

### `[notifications]`

Notifications are sent for mentions while the terminal doesn't have focus. A buffer gets one notification until you see it.

| Field | Meaning |
|---|---|
| `module` | Required when the table is present. `'bell'` rings the terminal bell. `'mac'` uses `terminal-notifier`. `'iterm2'` uses iTerm2's notification escape. |

Without this table, no notifications are sent.

### `[plugins]`

| Field | Default | Meaning |
|---|---|---|
| `modules` | none | Plugin names to load, in order. Each name loads `<directory>/<name>.lua`. |
| `directory` | `plugins` in the configuration directory | Where plugin files are found. |
| `custom` | | Per-plugin settings. A plugin named `hello` sees `[plugins.custom.hello]` as `api.config`. |

A plugin file returns a function that receives the plugin api. See the README and [hub/features/plugins/init.lua](../hub/features/plugins/init.lua).

## Networks

Each `[[networks]]` entry is one network that hub keeps a connection to. There can be any number, including none.

### Network settings

| Field | Default | Meaning |
|---|---|---|
| `id` | | Required. The network's name in the status bar, in `/net <id>` and in `@id` before a command, so keep it short. Letters, digits, `_`, `.` and `-`. Ids must be unique. |
| `features` | all features | Which [features](#features) run on this network. |
| `autoconnect` | `true` | Connect at startup, and after a reload that adds the network. With `false`, the network waits for `/connect`. |
| `reconnect.min_delay` | `1` | Seconds before the first reconnect attempt. |
| `reconnect.max_delay` | `300` | The longest wait between attempts. The delay doubles after each failure up to this limit, and returns to `min_delay` once a connection has stayed registered for a minute. It must not be below `min_delay`. |
| `reclaim_nick` | `true` | When the configured nick is taken at registration, watch it with MONITOR and take it back once it is free. |
| `quit_message` | `'snowcone'` | The QUIT message for `/disconnect`, `/reconnect` and quitting. |
| `snomask` | `'BFZbcklnsx'` | The server notice mask set after becoming an operator. Used only with the `snotice` feature. |
| `servers_file` | none | A Lua file describing the network's servers. See [The servers file](#the-servers-file). |
| `server`, `layers` | | How to connect. See [Connecting](#connecting). `server` is required. |
| `identity` | | Required. See [Registering](#registering). |
| `sasl` | | See [SASL](#sasl). |
| `oper`, `challenge` | | See [Becoming an operator](#becoming-an-operator). |
| `mention`, `watches` | | See [Mentions and watches](#mentions-and-watches). |

### Features

`features` lists what hub does on a network beyond keeping the connection. Leave it out to enable everything. Name only what you want, for example `features = ['chat']` for a network where you only chat.

| Feature | What it does |
|---|---|
| `chat` | Chat buffers, talk mode, mentions, chat history, `/list` and the chat commands. |
| `snotice` | Parses server notices into the connection, exit, ban, channel and address-range views (cliconn, cliexit, connload, exitload, bans, channels, netcount), sets the snomask after opering, and runs watches. |
| `oper` | The K-Line workflow (stage, test and send K-Lines, unklines and undlines), plus `/oper`, `/challenge`, `/masktrace` and `/testline`. |
| `topology` | Server populations from MAP, links from LINKS, versions, uptimes and DNS rotations, shown in the load views. |

An unknown feature name is an error.

### Connecting

A connection is a socket, then any `layers` in order, then IRC.

#### `[networks.server]`

| Field | Meaning |
|---|---|
| `host` | The hostname or address to connect to over TCP. |
| `port` | The TCP port. Required with `host`. |
| `path` | The path of a UNIX domain socket to connect to instead of `host` and `port`. |
| `fingerprint` | Pins the server's key; see below. |
| `capabilities` | Changes to the requested capabilities; see [Registering](#registering). |
| `username`, `password` | The server password; see [Registering](#registering). |

Give either `host` and `port`, or `path`:

```toml
[networks.server]
path = '/var/run/ircd.sock'
```

`fingerprint` is a Lua pattern matched against the whole connection description, for example `tcp=192.0.2.7:6697 tls=3f…`. If it doesn't match, the connection is dropped as `bad fingerprint` and not retried: the network stays idle until you fix the configuration and `/connect`. Write `tls=3f…$` to require the last TLS layer's key exactly, or a looser pattern if that suits you.

Each TLS layer reports `tls=` followed by the hex SHA-256 of the server's DER-encoded public key (SubjectPublicKeyInfo). This is the same value as:

```sh
openssl s_client -connect irc.example.net:6697 </dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | sha256sum
```

`/session` shows the description of the current connection under `transport`.

#### `[[networks.layers]]`

Layers wrap the socket in order. The first layer runs over the socket, and each later layer runs over the one before it. A proxy goes before the TLS layer that should travel through it:

```toml
[[networks.layers]]   # first: reach the proxy
type = 'socks'
host = '127.0.0.1'
port = 9050

[[networks.layers]]   # then: TLS to the IRC server, through the proxy
type = 'tls'
```

A layer with a missing or misspelled `type` is an error, never skipped, so a typo can't silently leave a connection unencrypted.

##### TLS layer

```toml
[[networks.layers]]
type = 'tls'
client_cert.file = 'client.pem'
verify_host = 'irc.example.net'
```

| Field | Meaning |
|---|---|
| `client_cert` | The client certificate, as PEM text. It is a [secret](#secrets), so write `client_cert.file = 'path'` to read it from a file. |
| `client_key` | The private key, as PEM text (also a secret). Defaults to `client_cert`, so one file holding both works. It must match the certificate. |
| `client_password` | A secret that decrypts an encrypted `client_key`. |
| `use_store` | With `true`, `client_key` names a key in an OpenSSL store (such as a `pkcs11:` URI) instead of holding PEM text. |
| `verify_host` | The name the server's certificate must match; see below. |
| `sni_host` | The server name sent in the handshake; see below. |
| `alpn` | Protocol names to offer with ALPN, in order. |

Notes:

- A plain string in `client_cert` or `client_key` is the PEM text itself, not a path. Use `.file` for a path.
- `verify_host` defaults to `sni_host` when that is set and non-empty. Otherwise it defaults to the host this layer runs over: `server.host`, or the `host` of the nearest `socks` or `http` layer before it.
  - An IP address is matched against the certificate's IP address entries.
  - Setting `verify_host` alone covers connecting by IP address, or to an onion service whose certificate names a public hostname.
- `verify_host = ''` disables certificate verification, so any certificate is accepted. Use it only when something else establishes trust, such as `server.fingerprint`.
- Over `server.path`, with no proxy layer before the TLS layer, there is no host to default to. `verify_host` is then required (a hostname, or `''`), and connecting without it fails.
- `sni_host` defaults to `verify_host` when that is set and non-empty, and otherwise to the same host. Set both only when they must differ. IP addresses are never sent as a server name, and `sni_host = ''` sends none.
- `alpn`: each name is 1 to 255 bytes, for example `alpn = ['irc']`. By default no ALPN is sent, because some servers and proxies refuse a handshake that offers only protocols they don't speak. Set it for a front end that routes by ALPN. Use `['http/1.1']` on a TLS layer that wraps an HTTPS proxy.

##### SOCKS5 layer

```toml
[[networks.layers]]
type = 'socks'
host = '127.0.0.1'
port = 1080
username = 'proxyuser'
password = 'proxypass'
```

`host` and `port` are required. `username` and `password` must be given together or both left out. One without the other is an error, not a silent connection without authentication. `password` is a [secret](#secrets). SOCKS5 allows neither to be empty, and each is at most 255 bytes.

##### HTTP CONNECT layer

```toml
[[networks.layers]]
type = 'http'
host = 'proxy.example.net'
port = 8080
```

This takes the same fields as SOCKS5. With `username` and `password`, the CONNECT request carries Basic authentication. Here the password may be empty, but the username can't contain `:`. For an HTTPS proxy, put a TLS layer (with `alpn = ['http/1.1']`) before this one.

### Registering

#### `[networks.identity]`

| Field | Default | Meaning |
|---|---|---|
| `nick` | | Required. The nick to register with, and the one `reclaim_nick` takes back. No spaces or control characters. |
| `user` | `nick` | The username sent in USER. |
| `gecos` | `nick` | The real name sent in USER. |

#### Server password

`server.password` is sent with PASS before registration. It is a [secret](#secrets). With `server.username`, PASS sends `username:password`, which is the form bouncers such as soju and ZNC use:

```toml
[networks.server]
host = 'bouncer.example.net'
port = 6697
username = 'me/libera'
password.prompt = 'bouncer password'
```

#### Capabilities

By default hub requests these capabilities when the server offers them:

`account-notify`, `account-tag`, `away-notify`, `batch`, `cap-notify`, `chghost`, `draft/chathistory`, `extended-join`, `extended-monitor`, `invite-notify`, `message-tags`, `multi-prefix`, `sasl`, `server-time`, `setname`, `soju.im/bouncer-networks`, `soju.im/bouncer-networks-notify`, `solanum.chat/identify-msg`, `solanum.chat/oper`, `solanum.chat/realhost`.

`server.capabilities` adds names to that list, or removes them with a leading `-`:

```toml
[networks.server]
capabilities = ['draft/event-playback', '-draft/chathistory']
```

In `/session`, under `caps`, enabled capabilities are green, and wanted capabilities that aren't enabled are red.

### SASL

```toml
[networks.sasl]
automatic = ['PLAIN', 'backup']

[[networks.sasl.credentials]]
mechanism = 'PLAIN'
username = 'mynick'
password.command = 'pass'
password.arguments = ['show', 'libera']

[[networks.sasl.credentials]]
name = 'backup'
mechanism = 'EXTERNAL'
```

`credentials` is a list of named credentials. A credential's `name` defaults to its `mechanism`.

`automatic` lists credential **names** to use at registration. They are tried in order, skipping any whose mechanism the server doesn't advertise, and the first that succeeds ends the list. A name that matches no credential stops registration with an error. Without `automatic`, SASL happens only when you run `/sasl <name>` with a credential's name.

| Field | Meaning |
|---|---|
| `name` | The name used in `automatic` and `/sasl`. Defaults to `mechanism`. |
| `mechanism` | Required; see the list below. |
| `username` | The authentication identity. |
| `password` | A [secret](#secrets): the password, or the passphrase of an encrypted `key`. |
| `key` | A secret: the private key for the challenge mechanisms. |
| `use_store` | With `true`, `key` names a key in an OpenSSL store instead of holding PEM text. |
| `authzid` | The authorization identity, to log in as someone else when the server allows it. |

Mechanisms and what each needs:

| Mechanism | Needs |
|---|---|
| `PLAIN` | `username`, `password` |
| `EXTERNAL` | nothing; the server uses the TLS client certificate |
| `SCRAM-SHA-1`, `SCRAM-SHA-256`, `SCRAM-SHA-512` | `username`, `password` |
| `ECDSA-NIST256P-CHALLENGE` | `username`, `key` (PEM) |
| `ECDH-X25519-CHALLENGE` | `username`, `key`: PEM, or the raw 32-byte private key in base64 |
| `ANONYMOUS` | `username` (sent as the trace text) |
| `AUTHCOOKIE` | `username`, `password`, `authzid` |

`/ecdsa_new`, `/x25519_new` and `/cert_new` make keys and certificates for these. `/ecdsa_fp` and `/cert_fp` show what to register with services.

### Becoming an operator

`[networks.oper]` logs in with OPER:

```toml
[networks.oper]
automatic = true
username = 'opername'
password = { command = 'pass', arguments = ['show', 'oper'] }
```

`[networks.challenge]` logs in with Solanum's CHALLENGE, using an RSA key:

```toml
[networks.challenge]
automatic = true
username = 'opername'
key.file = 'challenge.pem'
password.prompt = 'challenge key password'
```

| Field | Table | Meaning |
|---|---|---|
| `username` | both | Required. The operator name. |
| `password` | `oper` | Required. A [secret](#secrets). |
| `key` | `challenge` | Required. A secret holding the private key as PEM text, so usually `key.file`. With `use_store`, a store name instead. |
| `password` | `challenge` | A secret that decrypts an encrypted `key`. |
| `use_store` | `challenge` | With `true`, `key` names a key in an OpenSSL store. |
| `automatic` | both | Log in right after registration. If both tables set it, CHALLENGE is used. |

Without `automatic`, use `/oper` or `/challenge` (these need the `oper` feature). After you become an operator, the `snotice` feature sets the [snomask](#network-settings).

### Mentions and watches

`[networks.mention]` takes `patterns` like the [top-level table](#mention) and replaces the top-level patterns for this network.

`[[networks.watches]]` highlights connections whose server notices match a pattern, on networks with the `snotice` feature:

| Field | Default | Meaning |
|---|---|---|
| `pattern` | | Required. A PCRE2 regular expression when `rex_pcre2` is installed, otherwise a Lua pattern. `/stats` shows which, under `filters`. A pattern without capital letters ignores case. |
| `colour` | | The highlight colour: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan` or `white`. |
| `beep` | `false` | Ring the bell on a match. |
| `flash` | `false` | Flash the screen on a match. |
| `active` | `true` | With `false`, the watch is listed but doesn't match. |

The netcount view lists watches with their hit counts. Watches added with `/addwatch` are kept alongside configured ones. On reload, configured watches are replaced and keep their hit counts.

### The servers file

`servers_file` names a Lua file, relative to the configuration directory, that returns one table describing the network's servers. It is read when the configuration loads, and a file that can't be read or doesn't return a table stops the load. All keys are optional:

```lua
{
    primary_hub = 'hub.example',          -- topology: the root of the link tree
    flags = {'+'},                        -- rotation labels shown in the load views' Flags column
    servers = {
        ['alpha.example'] = {
            alias = 'al',                 -- short name in the connection views
            region = 'EU',                -- a label in `regions`
            ipv4 = '192.0.2.1',           -- addresses checked against DNS rotations
            ipv6 = '2001:db8::1',
            expect = {'+'},               -- which of `flags` the server should be in
        },
    },
    regions = {
        EU = {hostname = 'eu.irc.example', color = 'green'},  -- rotation hostname, looked up every 30 s
    },
    kline_reasons = {                     -- oper: {label, reason text} pairs to choose from
        {'spam', 'Spamming is not allowed'},
    },
    kline_tags = {'tagged'},              -- oper: tags to choose from
    net_tracks = {                        -- snotice: address ranges counted in netcount
        docs = {'192.0.2.0/24', '2001:db8::/32'},
    },
}
```

[tests/hub/fixtures/servers.lua](../tests/hub/fixtures/servers.lua) uses every key.

## Secrets

Fields that hold passwords, keys or certificates accept a secret, which is one of:

| Form | Value |
|---|---|
| `'text'` | The string itself. |
| `{ file = 'path' }` | The whole contents of the file. Relative paths are relative to the configuration directory. |
| `{ command = 'program', arguments = [...] }` | The program's output, as described below. |
| `{ prompt = 'label' }` | Asked for in the input line when needed, showing the network and label. Esc aborts it. |

A `command` secret has these fields:

| Field | Default | Meaning |
|---|---|---|
| `command` | | Required. The program to run. |
| `arguments` | none | Its arguments, passed as they are, with no shell. |
| `multiline` | `false` | With `false`, only the first line of output is used. With `true`, all of it is, as for a PEM key. |
| `use_tty` | `false` | With `false`, the program's standard input is empty. With `true`, the program shares snowcone's terminal as its standard input, for helpers that ask for a passphrase. Its output is still captured. |

A command that exits with a non-zero status fails that secret, and the failure is logged with its error output.

Secrets are resolved each time they are needed, at connect, registration or login, and are never stored. A prompt or command is therefore asked again on each reconnect.

In TOML, dotted keys keep these short:

```toml
password.file = '/etc/snowcone/server.pass'
password.prompt = 'Operator password'
password = { command = 'security', arguments = ['find-generic-password', '-s', 'irc', '-w'] }
```

## Reloading

`/reload` (or SIGUSR1) reads the configuration file and the servers files again, and loads new code, without dropping connections.

- **Networks:**
  - A network added to the file connects if `autoconnect` allows.
  - A network removed from the file disconnects.
- **Settings that apply at once:** `features`, `reconnect`, `reclaim_nick`, `quit_message`, `snomask`, `oper`, `challenge`, `mention`, `watches`, the servers file and the top-level tables.
- **Settings that wait for a new connection:** a change to `server`, `layers`, `identity` or `sasl` marks the network `restart pending: /reconnect` in `/networks` and `/session` until you reconnect.

A configuration that fails to load leaves the running one in place. The error is logged, hub switches to `/status` to show it, and `/stats` shows `last load failed` under `code`.
