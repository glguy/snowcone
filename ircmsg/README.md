# ircmsg

A small library for parsing IRC messages in place.

```c
  struct ircmsg parsed;
  char raw[] = "@key=val :nick!user@host PRIVMSG #channel :Hello, world.";

  parse_irc_message(raw, &parsed);

  /* effective result */
  parsed = (struct ircmsg) {
      .tags[0].key = "key",
      .tags[0].val = "val",
      .source = "nick!user@host",
      .command = "PRIVMSG",
      .args = {"#channel", "Hello, world."},
  };
  ```
