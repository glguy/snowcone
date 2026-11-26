# myhunspell

A small Lua binding for libhunspell: open a dictionary, check and
suggest words, and add words while the dictionary stays open.

```lua
local h = myhunspell.open('en_US.aff', 'en_US.dic')
h:spell 'word'      --> true
h:suggest 'wrod'    --> {'word', ...}
h:add 'snowcone'    -- accepted until the handle is closed
h:encoding()        --> 'UTF-8'
h:close()           -- also on __close and __gc; methods then raise
```

`open` raises, with a message naming the file, when either file is
missing, unreadable or not a regular file, or the .dic has no word count.

Words go to hunspell as bytes, unconverted, so they must already be in
the dictionary's encoding.
