# Snowcone - solanum server notice console

## Dependencies

```
apt install libgeoip-dev lua5.3 liblua5.3-dev lua-geoip lua-penlight lua-penlight-dev libuv1-dev
```

Penlight shows up in Lua as `pl`. If you get errors about finding things like `pl.app`, then Penlight isn't installed for the version of Lua you're building with.

## Usage

```
usage: snowcone
         [-h console_host]
         [-p console_port]
         [-S irc_socat]
         [-N irc_nick]
         [-U irc_user]
         [-G irc_gecos]
         [-X irc_password]
         [-O irc_oper]
         [-K irc_challenge_key]
         [-L init.lua]
```

To keep the IRC password out of your command-line arguments you can set the `IRC_PASSWORD` environment variable.

How I run this:

```
mkdir build
cd build
cmake ..
make
app/snowcone \
   -h ::1 -p 6000 \
   -S OPENSSL:[::1]:7000,certificate=certificate.pem \
   -N glguy \
   -U glguy@snowcone/libera \
   -X x \
   -L ../lua/init.lua
```

To connect to an unencrypted TCP port use: `-S TCP:${HOST}:${PORT}`

By adding a listener on port 6000 I get a Lua console that I can use to inspect the
program state.

```
$ rlwrap nc ::1 6000
filter='!~' -- set the filter to match connections without ident
print(filter) -- print the current filter
!~
filter=nil -- reset the filter
```

The tool automatically reloads the Lua logic when you save the file so you can
quickly adapt to changing circumstances, apply custom filters, etc.

Built-in keyboard shortcuts:

- <kbd>F1</kbd> - recent connections
  - <kbd>Q</kbd> - only live connections
  - <kbd>W</kbd> - only dead connections
  - <kbd>E</kbd> - all connections
  - <kbd>K</kbd> - **issue kline**
  - <kbd>⎋</kbd> - clear filters
  - <kbd>PgUp</kbd> - scroll up
  - <kbd>PgDn</kbd> - scroll down
- <kbd>F2</kbd> - server connection load
- <kbd>F3</kbd> - recent exits
- <kbd>F4</kbd> - server exit load
- <kbd>F5</kbd> - kline load
- <kbd>F6</kbd> - filter load
- <kbd>F7</kbd> - reconnecting nicknames
- <kbd>F8</kbd> - raw IRC console



Built-in Lua console commands

```
/reload - reruns the Lua program preserving the global environment
/restart - forces a restart of the Lua environment
```

## Known working clients

Snowcone expects to connect to your existing client. It works with irssi, weechat, and znc.

- [weechat IRC proxy documentation](https://weechat.org/files/doc/stable/weechat_user.en.html#relay_irc_proxy)
- [irssi IRC proxy documentation](https://github.com/irssi/irssi/blob/master/docs/proxy.txt)

## Connecting directly

Snowcone can connect directly to libera.chat and handle challenge on its own.

This requires an extra Lua dependency [openssl](https://github.com/zhaozg/lua-openssl) that isn't packaged in Debian.

```sh
luarocks install openssl
```

Here's the configuration script I use:

```sh
#!/bin/sh
IRC_PASSWORD=$(security find-generic-password -s iline -w) \
IRC_CHALLENGE_PASSWORD=$(security find-generic-password -s challenge -w) \
snowcone \
  -O glguy \
  -K challenge.p8 \
  -S OPENSSL:irc.libera.chat:6697,certificate=cert.pem,key=key.pem \
  -N snowcone
```