# snowcone - IRCd server notice console

## Dependencies

```
apt install lua5.3 liblua5.3-dev lua-penlight lua-penlight-dev libuv1-dev
```

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
   -Nglguy -Xglguy@snowcone/freenode: \
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
