# myhunspell

A small Lua binding for libhunspell: open a dictionary, check and
suggest words, and add words for the rest of the session.

```lua
local h = myhunspell.open('en_US.aff', 'en_US.dic')
h:spell 'word'      --> true
h:suggest 'wrod'    --> {'word', ...}
h:add 'snowcone'    -- accepted until the handle is closed
h:encoding()        --> 'UTF-8'
```

Words go to hunspell as bytes, in the dictionary's encoding.
