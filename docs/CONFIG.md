# Configuring snowcone hub

This document describes the configuration file of `snowcone hub`: where it lives, what goes in it and what each setting does. Every connection setting lives in a `[[networks]]` table. The schema is [hub/runtime/config_schema.lua](../hub/runtime/config_schema.lua).

Contents:

- [The file](#the-file)
- [A complete example](#a-complete-example)
- [Top-level tables](#top-level-tables): `ui`, `mention`, `notifications`, `plugins`
- [Networks](#networks)
  - [Network settings](#network-settings)
  - [Features](#features)
  - [Connecting](#connecting): `server`, `layers` (TLS, SOCKS5, HTTP CONNECT), `websocket`
  - [Registering](#registering): `identity`, `registration` (server password, capabilities)
  - [SASL](#sasl)
  - [Becoming an operator](#becoming-an-operator): `oper`
  - [Mentions and watches](#mentions-and-watches)
  - [The servers file](#the-servers-file)
- [Secrets](#secrets)
- [Reloading](#reloading)

## The file

The configuration is a TOML file. hub reads the first of these that applies:

1. the file last given to `/reload` (see [Reloading](#reloading)),
2. the file named with `--config=PATH`,
3. `$XDG_CONFIG_HOME/snowcone/hub.toml` (by default `~/.config/snowcone/hub.toml`).

A file given with `/reload` or `--config` must be named `*.toml`.

`$XDG_CONFIG_HOME/snowcone` is the *configuration directory*. Relative paths in the configuration, such as `servers_file`, `plugins.directory` and `{file = ...}` secrets, are relative to it.

Settings can be overridden on the command line with `key.path=value`, for example `ui.profile=chat`. Overrides are applied to the file's contents before checking.

A field of the wrong type, a missing required field or an unknown feature name stops the load with an error naming the field. So does a field the schema doesn't know, reported as `Unexpected field ...`, so a misspelled or outdated key is never ignored.

## A complete example

```toml
[ui]
profile = 'all'

[mention]
patterns = ['%f[%w]mynick%f[^%w]']

[notifications]
backend = 'mac'

[plugins]
modules = ['hello']

[[networks]]
id = 'libera'
servers_file = 'servers.toml'
snomask = '+BFZbcklnsx'

[networks.server]
host = 'irc.libera.chat'
port = 6697

[[networks.layers]]
type = 'tls'

[networks.identity]
nick = 'mynick'
realname = 'My Name'

[networks.sasl]
automatic = ['PLAIN']

[[networks.sasl.credentials]]
mechanism = 'PLAIN'
username = 'mynick'
password = { command = 'pass', arguments = ['show', 'libera'] }

[networks.oper]
automatic = ['challenge']

[[networks.oper.credentials]]
mechanism = 'challenge'
username = 'mynick'
key.file = 'libera-challenge.pem'
password.prompt = 'challenge key password'

[[networks.watches]]
pattern = 'badbot'
color = 'red'
beep = true

[[networks]]
id = 'oftc'
ircd = 'oftc-hybrid'
features = ['chat']

[networks.server]
host = 'irc.oftc.net'
port = 6697

[[networks.layers]]
type = 'tls'

[networks.identity]
nick = 'mynick'
```

In TOML, tables such as `[networks.server]` and `[[networks.layers]]` belong to the most recent `[[networks]]` entry above them.

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
| `backend` | Required when the table is present. `'bell'` rings the terminal bell. `'mac'` uses `terminal-notifier`. `'iterm2'` uses iTerm2's notification escape. |

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
| `ircd` | `'solanum'` | The server software the network runs: `'solanum'` or `'oftc-hybrid'`. It decides how server notices are recognized and parsed, what numerics mean, how `snomask` is set, how CHALLENGE works and how MAP, TESTMASK and TESTLINE replies read. OFTC hybrid has no MASKTRACE or TESTKLINE, and its connection notices carry no account, so a K-Line can't freeze one. |
| `features` | all features | Which [features](#features) run on this network. |
| `autoconnect` | `true` | Connect at startup, and after a reload that adds the network. With `false`, the network waits for `/connect`. |
| `reconnect.min_delay` | `1` | Seconds before the first reconnect attempt; at least 0.1. |
| `reconnect.max_delay` | `300` | The longest wait between attempts. The delay doubles after each failure up to this limit, and returns to `min_delay` once a connection has stayed registered for a minute. It must not be below `min_delay`. |
| `rate_limit.burst` | none | Lines that may go to the server at once. Without a `rate_limit` table, lines are never held back. With one, `burst` and `interval` are both required. |
| `rate_limit.interval` | none | Seconds to earn back one line of the burst, above 0. A line that has to wait shows as `queued` in chat and the console until it goes, or `unsent` if the connection ends first. A PONG goes ahead of waiting lines, and QUIT drops them and goes at once. `burst = 5` and `interval = 2` match RFC 1459's message timer. |
| `channels` | none | Channels to JOIN after every registration, so also after each reconnect, as many to a line as fit. Names only, without keys. A change takes effect at the next connection. |
| `reclaim_nick` | `true` | When the configured nick is taken at registration, watch it with MONITOR and take it back once it is free. |
| `quit_message` | `'snowcone'` | The QUIT message for `/disconnect`, `/reconnect` and quitting. |
| `snomask` | `'BFZbcklnsx'`, or `'bcfknrs'` on OFTC hybrid | What chooses the server notices to see, set after becoming an operator: on Solanum the server notice mask (`MODE nick +s mask`), on OFTC hybrid the user modes that select notices (`MODE nick +modes`). Used only with the `snotice` feature. |
| `servers_file` | none | A TOML file describing the network's servers. See [The servers file](#the-servers-file). |
| `server`, `layers`, `websocket` | | How to connect. See [Connecting](#connecting). `server` is required. |
| `identity`, `registration` | | What to register with. See [Registering](#registering). `identity` is required. |
| `sasl` | | See [SASL](#sasl). |
| `oper` | | See [Becoming an operator](#becoming-an-operator). |
| `mention`, `watches` | | See [Mentions and watches](#mentions-and-watches). |

### Features

`features` lists what hub does on a network beyond keeping the connection. Leave it out to enable everything. Name only what you want, for example `features = ['chat']` for a network where you only chat.

| Feature | Requires | What it does |
|---|---|---|
| `chat` | | Chat buffers, talk mode, mentions, chat history, `/list` and the chat commands. |
| `snotice` | | Parses server notices into the connection, exit, ban, channel and address-range views (cliconn, cliexit, connload, exitload, bans, channels, netcount), sets the snomask after opering, and runs watches. |
| `oper` | `snotice` | The K-Line workflow (stage, test and send K-Lines, unklines and undlines), plus `/oper`, `/masktrace` and `/testline`. A staged K-Line is shown and sent from snotice's views. |
| `topology` | | Server populations from MAP, links from LINKS, versions, uptimes and DNS rotations, shown in the load views. With `snotice`, shedding and drain notices also update `/maintenance` as they happen. |

An unknown feature name is an error, and so is a feature without the features it requires.

### Connecting

A connection is a socket to `server`, then any `layers` in order, then IRC, carried over a `websocket` if there is one.

#### `[networks.server]`

| Field | Meaning |
|---|---|
| `host` | The hostname or address to connect to over TCP. |
| `port` | The TCP port. Required with `host`. |
| `path` | The path of a UNIX domain socket to connect to instead of `host` and `port`. |

Give either `host` and `port`, or `path`:

```toml
[networks.server]
path = '/var/run/ircd.sock'
```

`/session` shows the description of the current connection under `transport`, for example `tcp=192.0.2.7:6697 tls=3f…`. Each TLS layer adds `tls=` and the key its server presented (see `pin` below), and a WebSocket adds `ws=` and the subprotocol the server chose.

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
| `client_key` | The [private key](#private-keys): PEM text, or a key in an OpenSSL store. Defaults to `client_cert`, so one file holding both works. It must match the certificate. |
| `client_password` | A secret that decrypts an encrypted `client_key`, or unlocks a stored one. |
| `verify_host` | The name the server's certificate must match; see below. |
| `sni_host` | The server name sent in the handshake; see below. |
| `alpn` | Protocol names to offer with ALPN, in order. |
| `pin` | The server's key, as the SHA-256 of its public key; see below. |

Notes:

- A plain string in `client_cert` or `client_key` is the PEM text itself, not a path. Use `.file` for a path.
- `verify_host` defaults to `sni_host` when that is set and non-empty. Otherwise it defaults to the host this layer runs over: `server.host`, or the `host` of the nearest `socks` or `http` layer before it.
  - An IP address is matched against the certificate's IP address entries.
  - Setting `verify_host` alone covers connecting by IP address, or to an onion service whose certificate names a public hostname.
- `verify_host = ''` disables certificate verification, so any certificate is accepted. Use it only when something else establishes trust, such as `pin`.
- Over `server.path`, with no proxy layer before the TLS layer, there is no host to default to. `verify_host` is then required (a hostname, or `''`), and connecting without it fails.
- `sni_host` defaults to `verify_host` when that is set and non-empty, and otherwise to the same host. Set both only when they must differ. IP addresses are never sent as a server name, and `sni_host = ''` sends none.
- `alpn`: each name is 1 to 255 bytes, for example `alpn = ['irc']`. By default no ALPN is sent, because some servers and proxies refuse a handshake that offers only protocols they don't speak. Set it for a front end that routes by ALPN. Use `['http/1.1']` on a TLS layer that wraps an HTTPS proxy.
- `pin` is 64 hex digits, in either case: the SHA-256 of the server's DER-encoded public key (SubjectPublicKeyInfo). If the server presents a different key, the connection is dropped with a message naming the layer, and not retried: the network stays idle until you fix the configuration and `/connect`. The pin is checked as well as `verify_host`, not instead of it. The value is the same as the layer's `tls=` in `/session`, and as:

  ```sh
  openssl s_client -connect irc.example.net:6697 </dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | sha256sum
  ```

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

#### `[networks.websocket]`

With this table, IRC is carried over a WebSocket, as the IRCv3 WebSocket specification describes. It runs over the last of the `layers`, or the socket when there are none. For a `wss://irc.example.net/webirc` address, add a TLS layer:

```toml
[networks.server]
host = 'irc.example.net'
port = 443

[[networks.layers]]
type = 'tls'
alpn = ['http/1.1']

[networks.websocket]
path = '/webirc'
```

| Field | Meaning |
|---|---|
| `host` | The `Host` header. Defaults to the host and port the WebSocket runs over: `server.host` and `server.port`, or the `host` and `port` of the last `socks` or `http` layer. |
| `path` | The path to request. Defaults to `/`. Must start with `/`. |
| `origin` | The `Origin` header. Set it for a server that only accepts listed origins; by default none is sent. |
| `subprotocols` | The IRCv3 subprotocols to offer, in order of preference: `binary.ircv3.net` and `text.ircv3.net`. Defaults to both, binary first. `[]` offers none; see below. |

None of these may contain spaces or control characters. Over `server.path`, with no proxy layer, there is no host to default to, so `host` is required.

Each line goes in its own message, and a carriage return ends a line just as a line feed does. When the server closes the WebSocket, the disconnect reason includes its close code and any reason it gave.

The server must choose one of the subprotocols offered, or the connection fails. Over `text.ircv3.net`, everything sent must be UTF-8.

A gateway that predates the IRCv3 subprotocols may refuse an offer of more than one (with HTTP 400) or ignore the offer. For one of those, set `subprotocols = []`: none is offered, the server must choose none, and messages are sent as text. The connection description then reads `ws=none`.

### Registering

#### `[networks.identity]`

| Field | Default | Meaning |
|---|---|---|
| `nick` | | Required. The nick to register with, and the one `reclaim_nick` takes back. No spaces or control characters. A nick the server refuses as erroneous stops the network from connecting until the configuration changes. |
| `user` | `nick` | The username sent in USER. |
| `realname` | `nick` | The real name sent in USER. |
| `bot` | `false` | Mark the connection as a bot: after registration, set the user mode the server names in ISUPPORT `BOT` (IRCv3 bot mode). A server that names none gets no mode, and the log says so. |

#### `[networks.registration]`

| Field | Meaning |
|---|---|
| `password` | The server password, sent with PASS before registration. It is a [secret](#secrets). |
| `username` | With `password`, PASS sends `username:password`. No `:`. |
| `capabilities` | Changes to the requested capabilities; see below. |

`username:password` is the form bouncers such as soju and ZNC use:

```toml
[networks.server]
host = 'bouncer.example.net'
port = 6697

[[networks.layers]]
type = 'tls'

[networks.registration]
username = 'me/libera'
password.prompt = 'bouncer password'
```

#### Capabilities

By default hub requests these capabilities when the server offers them:

`account-notify`, `account-tag`, `away-notify`, `batch`, `cap-notify`, `chghost`, `draft/chathistory`, `echo-message`, `extended-join`, `extended-monitor`, `invite-notify`, `labeled-response`, `message-tags`, `multi-prefix`, `sasl`, `server-time`, `setname`, `soju.im/bouncer-networks`, `soju.im/bouncer-networks-notify`, `solanum.chat/identify-msg`, `solanum.chat/oper`, `solanum.chat/realhost`.

`echo-message` is requested only together with `labeled-response` and `batch`, which hub uses to match each echo to the message it already shows.

`registration.capabilities` adds names to that list, or removes them with a leading `-`:

```toml
[networks.registration]
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

`automatic` lists credential **names** to use at registration. They are tried in order, skipping any whose mechanism the server doesn't advertise, and the first that succeeds ends the list. A name that matches no credential fails the load. Without `automatic`, SASL happens only when you run `/sasl`.

`/sasl <name>` authenticates with one credential. `/sasl` alone tries the `automatic` list, or the first credential when there is none.

| Field | Meaning |
|---|---|
| `name` | The name used in `automatic` and `/sasl`. Defaults to `mechanism`. |
| `mechanism` | Required; see the list below. |
| `username` | The authentication identity. |
| `password` | A [secret](#secrets): the password, or the passphrase of `key`. |
| `key` | The [private key](#private-keys) for the challenge mechanisms. |
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

`[networks.oper]` works like [SASL](#sasl): a list of named credentials, and the names to log in with at registration.

```toml
[networks.oper]
automatic = ['challenge']

[[networks.oper.credentials]]
mechanism = 'challenge'
username = 'opername'
key.file = 'challenge.pem'
password.prompt = 'challenge key password'

[[networks.oper.credentials]]
name = 'backup'
mechanism = 'password'
username = 'opername'
password = { command = 'pass', arguments = ['show', 'oper'] }
```

`automatic` lists credential names, tried in order right after registration until one makes you an operator. A name that matches no credential fails the load. Without `automatic`, nothing is tried until you run `/oper`.

| Field | Meaning |
|---|---|
| `name` | The name used in `automatic` and `/oper`. Defaults to `mechanism`. |
| `mechanism` | Required. `'password'` logs in with OPER; `'challenge'` with CHALLENGE, using an RSA key, in the form the network's [`ircd`](#network-settings) uses. |
| `username` | Required. The operator name. |
| `password` | With `'password'`, required: a [secret](#secrets) sent with OPER. With `'challenge'`, a secret that decrypts `key`. |
| `key` | With `'challenge'`, required: the [private key](#private-keys), usually `key.file`. |

`/oper <name>` logs in with one credential. `/oper` alone tries the `automatic` list, or the first credential when there is none. It needs the `oper` feature. After you become an operator, the `snotice` feature sets the [snomask](#network-settings).

### Mentions and watches

`[networks.mention]` takes `patterns` like the [top-level table](#mention) and replaces the top-level patterns for this network.

`[[networks.watches]]` highlights connections whose server notices match a pattern, on networks with the `snotice` feature:

| Field | Default | Meaning |
|---|---|---|
| `pattern` | | Required. A PCRE2 regular expression when `rex_pcre2` is installed, otherwise a Lua pattern. `/stats` shows which, under `filters`. A pattern without capital letters ignores case. |
| `color` | | The highlight color: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan` or `white`. |
| `beep` | `false` | Ring the bell on a match. |
| `flash` | `false` | Flash the screen on a match. |
| `active` | `true` | With `false`, the watch is listed but doesn't match. |

The netcount view lists watches with their hit counts. Watches added with `/addwatch` are kept alongside configured ones. On reload, configured watches are replaced and keep their hit counts.

### The servers file

`servers_file` names a TOML file, relative to the configuration directory and named `*.toml`, describing the network's servers. It is read when the configuration loads. A file that can't be read or parsed, or has a field of the wrong type or one the schema doesn't know, stops the load. All keys are optional:

```toml
primary_hub = 'hub.example'   # topology: the root of the link tree
flags = ['+']                 # rotation labels shown in the load views' Flags column
kline_tags = ['tagged']       # oper: tags to choose from

kline_reasons = [             # oper: reasons to choose from
  { name = 'spam', reason = 'Spamming is not allowed' },
]

[servers]
'alpha.example' = {
  alias = 'al',               # short name in the connection views
  region = 'EU',              # a label in `regions`
  ipv4 = '192.0.2.1',         # addresses checked against DNS rotations
  ipv6 = '2001:db8::1',
  expect = ['+'],             # which of `flags` the server should be in
}

[regions]                     # rotation hostnames, looked up every 30 s
EU = { hostname = 'eu.irc.example', color = 'green' }

[net_tracks]                  # snotice: address ranges counted in netcount
docs = ['192.0.2.0/24', '2001:db8::/32']
```

Server names contain dots, so they are quoted keys. An inline table may span lines (TOML 1.1), as `alpha.example` does here, or sit on one.

[tests/hub/fixtures/servers.toml](../tests/hub/fixtures/servers.toml) uses every key.

## Secrets

Fields that hold passwords, keys or certificates accept a secret, which is one of:

| Form | Value |
|---|---|
| `'text'` | The string itself. |
| `{ file = 'path' }` | The contents of the file, without its final line break. Relative paths are relative to the configuration directory. |
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

Secrets are resolved each time they are needed and are never stored. Those for the connection, registration (`password`) and automatic SASL are all resolved before connecting, so a prompt never holds an open connection; oper secrets are resolved at login. A prompt or command is therefore asked again on each reconnect.

In TOML, dotted keys keep these short:

```toml
password.file = '/etc/snowcone/server.pass'
password.prompt = 'Operator password'
password = { command = 'security', arguments = ['find-generic-password', '-s', 'irc', '-w'] }
```

### Private keys

A field that holds a private key (`client_key`, and `key` in SASL and `oper` credentials) takes a secret holding its PEM text, or a key in an OpenSSL store:

```toml
key.store = 'pkcs11:token=mytoken;object=oper'
```

The store is opened with the credential's `password`, or the layer's `client_password`, when one is given.

## Reloading

`/reload` (or SIGUSR1) reads the configuration file and the servers files again, and loads new code, without dropping connections.

`/reload FILE` switches to another configuration file. A relative `FILE` is relative to the configuration directory, and `~` is expanded. Once it loads, every later `/reload` and SIGUSR1 reads it too, until another file is given. A file that fails to load isn't remembered. The configuration directory stays the same, and command-line overrides still apply. `/stats` shows the file in use under `code`.

- **Networks:**
  - A network added to the file connects if `autoconnect` allows.
  - A network removed from the file disconnects.
- **Settings that apply at once:** `ircd` (except for the `snomask` modes, which are set when you become an operator), `features`, `reconnect`, `reclaim_nick`, `quit_message`, `snomask`, `oper`, `mention`, `watches`, the servers file and the top-level tables.
- **Settings that wait for a new connection:** a change to `server`, `layers`, `websocket`, `identity`, `registration` or `sasl` marks the network `restart pending: /reconnect` in `/networks` and `/session` until you reconnect.

A configuration that fails to load leaves the running one in place. The error is logged, hub switches to `/status` to show it, and `/stats` shows `last load failed` under `code`.
