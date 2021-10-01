# ircmsg

A small library for parsing IRC messages.

```c
  struct ircmsg parsed;
  char raw[] = "@key=val :nick!user@host PRIVMSG #channel :Hello, world.";
  
  parse_irc_message(raw, &parsed);
  
  /* effective result */
  parsed = (struct ircmsg) {
      .tags_n = 1,
      .tags[0].key = "key",
      .tags[0].val = "val",
      .source = "nick!user@host",
      .command = "PRIVMSG",
      .args_n = 2,
      .args = {"#channel", "Hello, world."},
  };
  ```
