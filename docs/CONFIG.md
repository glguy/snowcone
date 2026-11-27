# Configuring snowcone hub

This document describes the configuration file of `snowcone hub`: where it lives, what goes in it and what each setting does. Every connection setting lives in a `[[networks]]` table. The schema is [hub/runtime/config_schema.lua](../hub/runtime/config_schema.lua).

Contents:

- [The file](#the-file)
  - [Paths](#paths): how file names in the configuration and in commands are found
- [A complete example](#a-complete-example)
- [Top-level tables](#top-level-tables): `ui`, `mention`, `notifications`, `spell`, `plugins`
- [Networks](#networks)
  - [Network settings](#network-settings)
  - [Features](#features)
  - [Connecting](#connecting): `server`, `layers` (TLS, SOCKS5, HTTP CONNECT), `websocket`
  - [Registering](#registering): `identity`, `registration` (server password, capabilities)
  - [SASL](#sasl)
  - [Becoming an operator](#becoming-an-operator): `oper`
  - [Buffers](#buffers): channels to join, and how each buffer's messages count
  - [Hide rules](#hide-rules): messages the buffer view leaves out
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

`$XDG_CONFIG_HOME/snowcone` is the *configuration directory*. Files hub keeps by default, such as the `plugins` directory and the `words` list, are there.

Settings can be overridden on the command line with `key.path=value`, for example `ui.profile=chat`. A number in the path indexes a list, and a name after `networks` is a network's id: `networks.libera.reclaim_nick=false`. The value is read as a TOML value (`true`, `3`, `'text'`, `[1, 2]`), or else taken as text. Overrides are applied to the file's contents before checking.

A field of the wrong type, a missing required field or a value not among those a field lists stops the load with an error naming the field. So does a field the schema doesn't know, reported as `Unexpected field ...`, so a misspelled or outdated key is never ignored.

### Paths

Every setting that names a file or directory finds it the same way: `servers_file`, `plugins.directory`, `spell.dictionary`, `spell.personal`, and `{ file = ... }` [secrets](#secrets) (among them `client_cert.file` and `key.file`).

- A leading `~` or `~/` is your home directory. `~user` is not expanded.
- An absolute path is used as written.
- A relative path is relative to the directory of the configuration file, so a configuration and the files beside it can move together.

A file named in a command, as in `/reload FILE`, `/dump FILE`, `/ecdsa_new FILE`, `/ecdsa_fp FILE`, `/cert_new FILE` and `/cert_fp FILE`, is found the same way, except that a relative path is relative to the configuration directory. `--config=PATH` is relative to the current directory, like any path on a command line.

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

[[networks.buffers]]
name = '#snowcone'
join = true
label = 's'

[[networks.buffers]]
name = '#libera'
join = true
activity = false

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
| `theme` | `'modern'` | The look of the screen's chrome. `'modern'`, on terminals of 256 colors or more, draws the status bar and the detail pane's rule as bands of dark gray (the rule with ✕ to close at the left), buttons as chips of color, the choices of one setting as one control with the one in effect lit, table headers in a soft blue and muted text in gray. `'classic'`, as on terminals of fewer colors, keeps the status bar on the terminal's background, the rule a line with [CLOSE], buttons in brackets in reverse video, and ANSI colors. |
| `separators` | `'powerline'` | The glyphs between the status bar's fragments: `'powerline'` triangles, `'rounded'` half circles or `'slant'` diagonals, which need a Powerline or Nerd font, or `'plain'`, which needs none. |

### `[mention]`

| Field | Meaning |
|---|---|
| `patterns` | Lua patterns; a malformed one fails the load. A channel message matching any of them, or any of `regexes`, is a mention: its buffer is marked `!` and a notification may be sent. Your nick is not matched unless a pattern names it, so without any patterns no channel message is a mention. A private message to you is always a mention, whatever these say; see [Buffers](#buffers). A [buffer's own](#buffers) mention settings replace both rules. |
| `regexes` | PCRE2 regular expressions, matched as written: `(?i)` ignores case. They need `rex_pcre2`; a configuration with one fails to load without it, and so does one that doesn't compile. |

A network's own `[networks.mention]` replaces these for that network. It does not add to them. Setting either `patterns` or `regexes` replaces both lists: a network with only `regexes` uses none of the top-level `patterns`.

### `[notifications]`

Notifications are sent for mentions while the terminal doesn't have focus. A buffer gets one notification until you see it.

| Field | Meaning |
|---|---|
| `backend` | Required when the table is present. `'bell'` rings the terminal bell. `'mac'` uses `terminal-notifier`. `'iterm2'` uses iTerm2's notification escape. |

Without this table, no notifications are sent.

### `[spell]`

Spell checking for the messages you type. It needs snowcone built with hunspell, and a hunspell dictionary.

| Field | Default | Meaning |
|---|---|---|
| `dictionary` | | Required when the table is present. A hunspell dictionary without its extension: `'/usr/share/hunspell/en_US'` reads `en_US.aff` and `en_US.dic`; naming either file works too. |
| `personal` | `words` in the configuration directory | Your own words, one per line, also accepted. `/spell_add` appends to it. |

While you talk (not in commands, filters or prompts), misspelled words are underlined in red. The word you are still typing isn't flagged. Words with digits, URLs, channel names, and the nicks in the shown channel (with their possessives) are never checked. Meta-$ replaces the misspelled word at the cursor, or else the last one before it, with each suggestion in turn, and then the word as it was. Ctrl-_ undoes the whole run. A word with formatting codes inside it is left for you to fix by hand. `/spell WORD` shows whether a word is spelled right and offers suggestions. `/spell_add WORD` accepts it from now on.

A dictionary that isn't UTF-8 (many `en_US` files are ISO8859-1) checks only words written entirely in ASCII. Words in a script the dictionary doesn't cover, such as Cyrillic against `en_US`, are all flagged.

`/reload` opens the dictionary again and re-reads the personal list, so it picks up a dictionary installed after an error, or words added by hand.

Without this table, or without hunspell, nothing is checked.

### `[plugins]`

| Field | Default | Meaning |
|---|---|---|
| `modules` | none | Plugin names to load, in order. Each name loads `<directory>/<name>.lua`. |
| `directory` | `plugins` in the configuration directory | Where plugin files are found. |
| `custom` | | Per-plugin settings. A plugin named `hello` sees `[plugins.custom.hello]` as `api.config`. |

A plugin file returns a function that receives the plugin api. See [PLUGINS.md](PLUGINS.md).

## Networks

Each `[[networks]]` entry is one network that hub keeps a connection to. There can be any number, including none.

### Network settings

| Field | Default | Meaning |
|---|---|---|
| `id` | | Required. The network's name in the status bar, in `/net <id>` and in `@id` before a command, so keep it short. Letters, digits, `_`, `.` and `-`. Ids must be unique. |
| `ircd` | `'solanum'` | The server software the network runs: `'solanum'` or `'oftc-hybrid'`. It decides how server notices are recognized and parsed, what numerics mean, how `snomask` is set, how CHALLENGE works and how MAP, TESTMASK and TESTLINE replies read. OFTC hybrid has no MASKTRACE, CHANTRACE or TESTKLINE, and its connection notices carry no account, so a K-Line can't freeze one. |
| `features` | all features | Which [features](#features) run on this network. |
| `autoconnect` | `true` | Connect at startup, and after a reload that adds the network. With `false`, the network waits for `/connect` (as `/connect@id` when no network is current), and stays out of the status bar until then. |
| `reconnect.min_delay` | `1` | Seconds before the first reconnect attempt; at least 0.1. |
| `reconnect.max_delay` | `300` | The longest wait between attempts. The delay doubles after each failure up to this limit, and returns to `min_delay` once a connection has stayed registered for a minute. A server that refuses you as banned (465) is retried after this delay at once, since a ban won't lift soon. It must not be below `min_delay`. |
| `rate_limit.burst` | none | Lines that may go to the server at once. Without a `rate_limit` table, lines are never held back. With one, `burst` and `interval` are both required. |
| `rate_limit.interval` | none | Seconds to earn back one line of the burst, above 0. A line that has to wait shows as `queued` in chat and the console until it goes, or `unsent` if the connection ends first. A PONG goes ahead of waiting lines, and QUIT drops them and goes at once. `burst = 5` and `interval = 2` match RFC 1459's message timer. |
| `buffers` | none | Channels to join, and settings for the buffers of channels and nicks. See [Buffers](#buffers). |
| `hide` | none | Rules for the messages the buffer view leaves out. See [Hide rules](#hide-rules). |
| `reclaim_nick` | `true` | When the wanted nick is taken, or the server changes our nick, watch the wanted one with MONITOR and take it back once it is free. A nick the server holds for a while, or refuses for changing nick too fast, is tried again later. Behind a bouncer, the nick it gives us, and changes made by its other clients, are left alone. The wanted nick is the configured one, or the last given to `/nick`, which later connections register with too until the configured nick changes. |
| `quit_message` | `'snowcone'` | The QUIT message for `/disconnect`, `/shelve`, `/reconnect` and quitting. |
| `snomask` | `'BFZbcklnsx'`, or `'bcfknrs'` on OFTC hybrid | What chooses the server notices to see, set after becoming an operator: on Solanum the server notice mask (`MODE nick +s mask`), on OFTC hybrid the user modes that select notices (`MODE nick +modes`). Used only with the `snotice` feature. |
| `servers_file` | none | A TOML file describing the network's servers. See [The servers file](#the-servers-file). |
| `server`, `layers`, `websocket` | | How to connect. See [Connecting](#connecting). `server` is required. |
| `identity`, `registration` | | What to register with. See [Registering](#registering). `identity` is required. |
| `sasl` | | See [SASL](#sasl). |
| `oper` | | See [Becoming an operator](#becoming-an-operator). |
| `mention`, `watches` | | See [Mentions and watches](#mentions-and-watches). |

### Features

`features` lists what hub does on a network beyond keeping the connection and answering queries: `/who`, `/whois`, `/wii`, `/whowas`, `/stats`, `/trace`, `/etrace`, `/masktrace`, `/chantrace`, `/motd`, `/info`, `/serverhelp`, `/lusers`, `/privs`, `/scan`, `/list` and `/findforwards` work on every network. Leave it out to enable everything. Name only what you want, for example `features = ['chat']` for a network where you only chat.

| Feature | Requires | What it does |
|---|---|---|
| `chat` | | Chat buffers, talk mode, mentions, chat history and the chat commands. |
| `snotice` | | Parses server notices into the connection, exit, ban, channel and address-range views (cliconn, cliexit, connload, exitload, bans, channels, netcount), sets the snomask after opering, and runs watches. |
| `oper` | `snotice` | The K-Line workflow (stage, test and send K-Lines, unklines and undlines), plus `/testline`, `/kill`, `/wallops`, `/operwall`, and bans sent as typed: `/unkline`, `/dline`, `/undline`, `/xline`, `/unxline`, `/resv`, `/unresv`. A staged K-Line is shown and sent from snotice's views. `/oper` doesn't need it. |
| `admin` | | Commands for running the servers: on Solanum its modules, with `/modlist` (shown as a table), `/modload`, `/modunload`, `/modreload` and `/modrestart`; and `/serverconnect`, `/serverquit`, `/serverrehash`, `/serverdie` and `/serverrestart` (CONNECT, SQUIT, REHASH, DIE, RESTART); and on Solanum `/grant`, `/dehelper` and `/shedding`. Leave it out for opers without these privileges, so the commands don't show. |
| `topology` | `snotice` | Server populations from MAP, links from LINKS, versions, uptimes and DNS rotations, shown in the load views. Shedding and drain notices update `/maintenance` as they happen. |

A feature without the features it requires is an error.

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
- `pin` is 64 hex digits, in either case: the SHA-256 of the server's DER-encoded public key (SubjectPublicKeyInfo). If the server presents a different key, the connection is dropped, before anything is sent over that layer, with a message naming the layer, and not retried: the network stays idle until you fix the configuration and `/connect`. The pin is checked as well as `verify_host`, not instead of it. The value is the same as the layer's `tls=` in `/session`, and as:

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

`host` and `port` are required. `username` and `password` must be given together or both left out. One without the other fails the connection attempt (the load doesn't catch it), rather than connecting silently without authentication. `password` is a [secret](#secrets). SOCKS5 allows neither to be empty, and each is at most 255 bytes.

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
| `mechanism` | Required; see the list below. The load doesn't check it: a mechanism not listed, or a field it needs that is missing, fails when the credential is used. |
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

`/oper <name>` logs in with one credential. `/oper` alone tries the `automatic` list, or the first credential when there is none. It works on any network, with or without the `oper` feature. After you become an operator, the `snotice` feature sets the [snomask](#network-settings).

### Buffers

Each `[[networks.buffers]]` entry names a channel or nick and sets how its buffer behaves. A buffer without an entry has the defaults.

| Field | Default | Meaning |
|---|---|---|
| `name` | | Required. The channel or nick, matched with the network's casemapping. Two entries can't name the same buffer. |
| `join` | `false` | JOIN the channel after every registration, so also after each reconnect. The channels to join go as many to a line as fit, in the order of the entries. Leave it out for a channel a bouncer joins for you, or for a nick. A new connection also rejoins the channels you were in when the last one ended, configured or not, and sets you away again if you were. Closing a channel's buffer, even while disconnected, leaves it out. |
| `key` | none | The channel key (`+k`) to join with. A key you joined with later, or one set while you are in the channel, takes its place until you leave. |
| `mention.patterns`, `mention.regexes` | | The buffer's own mention patterns and regular expressions, as in the [top-level table](#mention). See below. |
| `activity` | `true` | With `false`, only mentions mark the buffer unseen. Other messages are still stored. |
| `label` | the first free one | The buffer's key in the jump pane (`j` in the buffer view): one letter or digit. No other buffer gets that key, even while this buffer isn't open. Two entries can't have the same label. With `false`, the buffer has no key, but you can still click it. |
| `hidden` | `false` | Leave the buffer out of the jump pane. It still has a label, and typing that label in the jump pane still goes to the buffer. With `label = false` as well, the buffer can't be reached from the jump pane at all. |

Other people's messages mark their buffer unseen (`+`, yellow); joins, parts and your own lines don't. A mention marks it `!` in magenta instead: Meta-A goes to it first, and it can send a [notification](#notifications). In a channel, a mention is a message matching the [mention patterns](#mention). In a private buffer, a mention is a message addressed to your nick, other than a CTCP request such as VERSION (an action is a mention). A message to a broadcast mask, or to a nick you no longer have, is not. The network and top-level mention patterns don't apply to private buffers.

A buffer's own `mention.patterns` or `mention.regexes` replace those rules for that buffer, in a channel or a private buffer. Setting either one replaces both lists:

- `patterns = []`: nothing in the buffer is a mention.
- `patterns = ['']`: every message is a mention.

```toml
[[networks.buffers]]
name = '#busy'
join = true
activity = false
label = false

[[networks.buffers]]
name = '#alerts'
join = true
mention.patterns = ['']

[[networks.buffers]]
name = 'somebot'
mention.patterns = []
activity = false
hidden = true
```

`#busy` is marked only by mentions, every message in `#alerts` is a mention, and `somebot`'s messages never mark its buffer.

### Hide rules

The buffer view leaves out the messages that hide rules hide. Meta-H shows them in the buffer shown, and again hides them. Each buffer keeps its own setting while you switch between buffers, and its mode reads `show` while it shows them. Bringing a hidden message into view, as a click on a reply does, shows them too. `/filter` searches every message, hidden or not.

Each `[[networks.hide]]` entry is a rule. They are tried in order and the first that matches decides. After them come built-in rules that hide joins, parts, quits, nick changes, account changes and host changes. A rule with `action = 'show'` overrides the rules after it, the built-in ones included.

A rule with `action = 'discard'` keeps the messages it matches out of buffers altogether: they aren't stored, a private message doesn't open a buffer, and they are left out of chat history too. A CTCP request it discards gets no reply. The console still shows them, so it is the place to look when a discarding rule seems to match too much.

| Field | Matches |
|---|---|
| `buffer` | The buffer the message is placed in: a channel or a nick, in any case the network's casemapping allows. |
| `nick` | The sender's nick, in any case. |
| `account` | The sender's account, in any case, from the message's `account` tag. A message without one never matches. |
| `command` | The IRC command, in capitals: `PRIVMSG`, `NOTICE`, `WALLOPS`, `OPERWALL`, `JOIN`, `PART`, `KICK`, `TOPIC`, `MODE`, `QUIT`, `NICK`, `ACCOUNT`, `CHGHOST`, or a channel error's numeric by its digits, such as `'474'`. A command that never reaches a buffer fails the load. |
| `pattern` | The text of a PRIVMSG or NOTICE, as a Lua pattern. |
| `regex` | The text of a PRIVMSG or NOTICE, as a PCRE2 regular expression, matched as written: `(?i)` ignores case. A configuration with one fails to load without `rex_pcre2`. |
| `action` | `'hide'`, the default, `'show'` or `'discard'`. |

Each matching field takes one string or a list of them, and a list matches when any of its entries does. A rule matches when every field it has matches. It must have at least one, can't have both `pattern` and `regex`, and fails the load with a pattern or regex that doesn't compile. A rule that could never match fails the load too: one with an empty list, a `nick` or `account` holding `!`, `@`, `*`, `?`, a comma or a space (they are matched exactly, not as masks), or a `pattern` or `regex` with a `command` list that has neither PRIVMSG nor NOTICE.

The text `pattern` and `regex` see has its IRC formatting removed, and an action (`/me`) is seen without its CTCP framing. They never match other commands, such as the reason of a PART or QUIT.

A hidden message is kept in its buffer. It never marks the buffer unseen and is never a mention, so it sends no notification. A hidden private message from someone new still opens a buffer for them, which shows nothing until Meta-H; discard such messages instead. Your own messages are never hidden or discarded. The message's detail pane names the rule that decided it, such as `networks.libera.hide.1`.

```toml
[[networks.hide]]
buffer = '#libera-audit'
nick = 'OperServ'
pattern = '^KLINE:EXPIRE:'

[[networks.hide]]
buffer = '#project'
nick = ['ci-bot', 'deploy-bot']

[[networks.hide]]
buffer = '#small'
command = ['JOIN', 'PART', 'QUIT']
action = 'show'
```

A message is decided as it reaches its buffer, including from chat history. A QUIT or NICK reaches each buffer of a channel the user was in, so a rule naming one buffer can hide it there and not in the others. A reload changes how later messages are decided, not the ones already kept.

### Mentions and watches

`[networks.mention]` takes `patterns` and `regexes` like the [top-level table](#mention) and replaces the top-level ones for this network. A [buffer's own](#buffers) replace both.

`[[networks.watches]]` highlights connections whose server notices match a pattern, on networks with the `snotice` feature:

| Field | Default | Meaning |
|---|---|---|
| `pattern` | | Required. A PCRE2 regular expression when `rex_pcre2` is installed, otherwise a Lua pattern. `/client` shows which, under `filters`. A pattern without capital letters ignores case. One that doesn't compile fails the load, and so does a Lua pattern that repeats more than two items with `*`, `+` or `-`. |
| `color` | | The highlight color: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan` or `white`. |
| `beep` | `false` | Ring the bell on a match. |
| `flash` | `false` | Flash the screen on a match. |
| `active` | `true` | With `false`, the watch is listed but doesn't match. |

The netcount view lists watches with their hit counts. `/addwatch 'pattern' [color] [[no]beep] [[no]flash]` adds a watch, its options in any order, and `/editwatch number` changes one: while you type it, the placeholders show the watch's settings. Watches added with `/addwatch` are kept alongside configured ones. On reload, configured watches are replaced and keep their hit counts.

### The servers file

`servers_file` names a TOML file (found as [Paths](#paths) describes) named `*.toml`, describing the network's servers. It is read when the configuration loads. A file that can't be read or parsed, or has a field of the wrong type or one the schema doesn't know, stops the load. All keys are optional:

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
| `{ file = 'path' }` | The contents of the file (see [Paths](#paths)), without its final line break. |
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

`/reload FILE` switches to another configuration file, found as [Paths](#paths) describes for commands. Once it loads, every later `/reload` and SIGUSR1 reads it too, until another file is given. A file that fails to load isn't remembered. The configuration directory stays the same, and command-line overrides still apply. `/client` shows the file in use under `code`, as `config`.

- **Networks:**
  - A network added to the file connects if `autoconnect` allows.
  - A network removed from the file disconnects.
  - `autoconnect` matters only for a network the reload adds. Changing it on a network already there neither connects nor disconnects it; use `/connect`, `/disconnect` or `/shelve`.
- **Settings that apply at once:** `ircd`, `features`, `reconnect`, `rate_limit`, `reclaim_nick`, `quit_message`, `mention`, `watches`, `hide` (for messages that arrive afterwards), the `mention`, `activity`, `label` and `hidden` of `buffers`, the servers file and the top-level tables. Messages already received keep how they counted.
- **Settings that wait for the next time you become an operator:** `snomask`, and the snomask modes a change of `ircd` implies. `oper` credentials are used by the next `/oper`, and `oper.automatic` at the next registration.
- **Settings that wait for a new connection:** `join` and `key` in `buffers`; hub doesn't join or part channels on a reload. A change to `server`, `layers`, `websocket`, `identity`, `registration` or `sasl` marks the network `restart pending: /reconnect` in `/networks` and `/session` until you reconnect.

A configuration that fails to load leaves the running one in place. The error is logged, hub switches to `/status` to show it, and `/client` shows `last load` with the time, `failed:` and the error under `code`.
