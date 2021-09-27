# snowcone - IRCd server notice console

## Dependencies

```
apt install libgeoip-dev lua5.3 liblua5.3-dev lua-geoip lua-penlight lua-penlight-dev libuv1-dev
```

Penlight shows up in Lua as `pl`. If you get errors about finding things like `pl.app`, then Penlight isn't installed for the version of Lua you're building with.

## Usage

How I run this

```
mkdir build
cd build
cmake ..
make
app/snowcone \
   -h ::1 -p 6000 \
   -S OPENSSL:[::1]:7000,certificate=certificate.pem \
   -Nglguy -Xglguy@snowcone/libera: \
   ../lua/init.lua
```

To connect to an unencrypted TCP port use: `-S TCP:${HOST}:${PORT}`

By adding a listener on port 6000 I get a Lua console that I can use to inspect the
program state.

```
rlwrap nc ::1 6000
```

The tool automatically reloads the Lua logic when you save the file so you can
quickly adapt to changing circumstances, apply custom filters, etc.

Built-in keyboard shortcuts:

```
F1 - connections
F2 - servers
F3 - klines
F4 - filters
F5 - repeats
Q - only live connections
W - only dead connections
E - all connections
Page Up - scroll to older connections
Page Down - scroll to newer connections
```

Built-in Lua console commands

```
/reload - reruns the Lua program preserving the global environment
/restart - forces a restart of the Lua environment
```

## Known working clients

snowcone expects to connect to your existing client. We know it works with irssi, weechat, and znc.

* https://weechat.org/files/doc/stable/weechat_user.en.html#relay_irc_proxy
* https://github.com/irssi/irssi/blob/master/docs/proxy.txt
