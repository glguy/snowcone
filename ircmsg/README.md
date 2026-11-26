# ircmsg

A small C++ library for parsing IRC messages in place.

```cpp
char raw[] = "@key=val :nick!user@host PRIVMSG #channel :Hello, world.";

// Throws irc_parse_error on malformed input. The result's string_views
// point into raw, which is modified, so raw must outlive parsed.
ircmsg const parsed = parse_irc_message(raw);

/* effective result */
// parsed.tags    == {{"key", "val"}}
// parsed.source  == "nick!user@host"
// parsed.command == "PRIVMSG"
// parsed.args    == {"#channel", "Hello, world."}
```

`parse_irc_tags` parses a bare tag list (without the leading `@`) the same way.
