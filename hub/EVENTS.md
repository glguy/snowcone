# hub event topics

Every topic passed to `bus.emit` with a literal name is listed here;
`tests/hub/test-structure.lua` checks it. Events that relate to a network
carry `net`, the network id.

| Topic | Payload | Emitted by |
| --- | --- | --- |
| `app.reloaded` | `{generation, first}` after a generation becomes current | app |
| `app.quit` | `{}` when quitting starts, before networks disconnect | app |
| `clock.tick` | `{now}` once a second, when the tick runs | app |
| `log` | `{category, text, time, timestamp, net?}` for each log line | runtime/log |
| `task.prompt` | `{task, label, net?}` a task waits for a secret; answer with `task.answer(task, text)` | runtime/task |
| `net.state` | `{net, phase, prev, reason?}` on every phase change | net/manager |
| `net.connected` | `{net, fingerprint}` transport is up, registration starts | net/manager |
| `net.registered` | `{net, nick}` end of MOTD after welcome | net/registration |
| `net.closed` | `{net, reason}` an attempt ended | net/manager |
| `net.removed` | `{net}` a network left the configuration and its record is gone; drop its feature state | net/manager |
| `irc.message` | `{net, msg}` every inbound message after the model update, except replayed history (chathistory batches) | net/manager |
| `irc.sent` | `{net, msg}` outbound, secrets masked, once per line when it is sent or queued; `msg.delivery` is `{state = 'queued'}` for a queued line, later `'sent'` (with `delay`, seconds) or `'dropped'`, and absent for a line written at once | net/send |
| `irc.batch` | `{net, type, params, messages, label}` when a batch closes, with every message in it; `label` when it is a labeled reply | net/batch |
| `irc.nick` | `{net, old, new, self}` | net/handlers |
| `irc.oper` | `{net}` once per connection, when we are an operator (RPL_YOUREOPER, or user mode o) | net/handlers |
| `irc.isupport` | `{net, key, value}` value nil when removed, true without a value | net/irc |
| `snote` | `{net, name, server, time, timestamp, ...fields}` a parsed server notice | features/snotice |
| `snote.<name>` | the same event, by notice name | features/snotice |
| `topology.map` | `{net, population}` a MAP reply ended; population is `[server] = users` | features/topology |
| `chat.message` | `{net, target, msg, mention, activity}` a message added to a buffer | features/chat |
| `chat.buffer` | `{net, target, opened}` a buffer opened or closed | features/chat |
| `chat.focus` | `{net, target}` /talk asks the UI to show a buffer | features/chat |
| `chat.show_list` | `{net}` /list asks the UI to show the list | features/chat |
| `chat.show_channel` | `{net, target}` /chaninfo asks the UI to show a channel's information | features/chat |
| `quote.sent` | `{net, reply}` /quote sent a labeled line; `reply` is a `hub.QuoteReply` filled in place when the reply comes; the UI shows it | commands/core |
| `chat.whois` | `{net, whois}` a WHOIS reply ended, as a `hub.Whois`; the UI shows it | features/chat |
| `chat.whowas` | `{net, whowas}` a WHOWAS reply ended, as a `hub.Whowas`; the UI shows it | features/chat |
| `eval.result` | `{value}` /eval returned values: `{code, n, ...}`, live; the UI shows them | commands/core |
| `notify.alert` | `{net, kind, text, beep?, flash?, color?}` something wants attention; the UI and notify decide how | features (snotice watches) |
