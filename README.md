# Snowcone - solanum server notice console

## Dependencies

```sh
apt install libgeoip-dev liblua5.3-dev libuv1-dev lua-penlight check
```

Penlight shows up in Lua as `pl`. If you get errors about finding things like `pl.app`, then Penlight isn't installed for the version of Lua you're building with.

## Usage

Please see `man snowcone` or [snowcone.txt](snowcone.txt) for detailed usage instructions.

How I run this:

```sh
cmake -B build
make -C build
build/app/snowcone \
   -h ::1 -p 6000 \
   -S OPENSSL:[::1]:7000,certificate=certificate.pem \
   -N glguy \
   -U glguy@snowcone/libera \
   -X x \
   -L lua/init.lua
```

## Lua console

Snowcone supports running an interactive Lua prompt on a network port that can be used to inspect the live Lua environment and set parameters that don't have a UI exposed yet.

By adding a listener on port 6000 I get a Lua console that I can use to inspect the program state. The `rlwrap` program is handy for getting a nicer text input to `nc`.

```
$ snowcone ... -h ::1 -p 6000 ...

$ rlwrap nc ::1 6000
filter='!~' -- set the filter to match connections without ident
print(filter) -- print the current filter
!~
filter=nil -- reset the filter
```

## Known working clients

Snowcone expects to connect to your existing client. It works with irssi, weechat, and ZNC.

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
  -M EXTERNAL \
  -N snowcone
```
