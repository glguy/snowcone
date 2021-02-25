# snote_con

How I run this currently

```
mkdir build
cd build
cmake ..
make
./snote_con -p6000 ../logic.lua <(tail -qf $LOGS/*.net/$(date +%Y-%m-%d).log)
```
