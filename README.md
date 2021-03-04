# snote_con

How I run this currently

```
mkdir build
cd build
cmake ..
make
./snote_con -h::1 -p6000 ../logic.lua <(tail -qf $LOGS/*.net/$(date +%Y-%m-%d).log)
```

By adding a listener on port 6000 I can send in Lua code via a separate window instead of
competing with the output window. Long-term I want to integrate nicer TTY rendering and
readline into the tool, but it's not there.

```
rlwrap nc ::1 6000
```

The tool automatically reloads the Lua logic when you save the file so you can
quickly adapt to changing circumstances, apply custom filters, etc.

Built-in keyboard shortcuts:

```
F1 - connections
F2 - servers
F3 - repeats
Q - only live connections
W - only dead connections
E - all connections
```
