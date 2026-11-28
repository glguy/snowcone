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
| `task.canceled` | `{task, name, net?}` a task was canceled; a prompt it asked goes | runtime/task |
| `net.state` | `{net, phase, prev, reason?, kind?}` on every phase change; `reason` and `kind` when a connection ended (as for `net.closed`) | net/manager |
| `net.connected` | `{net, transport}` transport, as described, is up, registration starts | net/manager |
| `net.registered` | `{net, nick}` end of MOTD after welcome | net/registration |
| `net.closed` | `{net, reason, kind}` an attempt ended: `reason` is the text logged, `kind` one of `local` (we ended it), `config` (stays down), `banned` (465; retries after `reconnect.max_delay`), `refused`, `timeout`, `stream`, `server` (the server's ERROR) | net/manager |
| `net.shelved` | `{net}` /shelve set a network aside; it is disconnecting, and out of the status bar until connected | net/manager |
| `net.removed` | `{net}` a network left the configuration and its record is gone; drop its feature state | net/manager |
| `irc.message` | `{net, msg}` every inbound message after the model update, except replayed history (chathistory batches) | net/manager |
| `irc.sent` | `{net, msg}` outbound, secrets masked, once per line when it is sent or queued; `msg.delivery` is `{state = 'queued'}` for a queued line, later `'sent'` (with `delay`, seconds) or `'dropped'`, and absent for a line written at once | net/send |
| `irc.batch` | `{net, type, params, messages, label}` when a batch closes, with every message in it; `label` when it is a labeled reply | net/batch |
| `irc.nick` | `{net, old, new, self}` | net/handlers |
| `irc.oper` | `{net}` when we become an operator (RPL_YOUREOPER, or user mode o); again after losing it (user mode -o, which clears `irc.oper`) and regaining it | net/handlers |
| `irc.isupport` | `{net, key, value}` value nil when removed, true without a value | net/irc |
| `snote` | `{net, name, server, time, timestamp, ...fields}` a parsed server notice | features/snotice |
| `snote.<name>` | the same event, by notice name | features/snotice |
| `topology.map` | `{net, population}` a MAP reply ended; population is `[server] = users` | features/topology |
| `oper.staged` | `{net, action}` a K-Line, unkline or undline was staged, replacing what was | features/oper |
| `chat.message` | `{net, target, msg, mention, activity, hidden}` a message added to a buffer; `hidden` when a hide rule hides it there, and then never a mention or activity | features/chat |
| `chat.buffer` | `{net, target, opened}` a buffer opened or closed | features/chat |
| `chat.rename` | `{net, from, to}` a private buffer follows its nick's change from `from` to `to` | features/chat |
| `chat.focus` | `{net, target}` /talk asks the UI to show a buffer | features/chat |
| `chat.forward` | `{net, from, to}` the server forwarded our JOIN of `from` to `to` (470) | features/chat |
| `chat.show_channel` | `{net, target}` /chaninfo asks the UI to show a channel's information | features/chat |
| `quote.sent` | `{net, reply}` /quote sent a labeled line; `reply` is a `hub.QuoteReply` filled in place when the reply comes; the UI shows it | commands/quote |
| `query.who` | `{net, who}` a WHO reply ended, as a `hub.Who`; the UI shows it | features/queries |
| `query.whois` | `{net, whois}` a WHOIS reply ended, as a `hub.Whois`; the UI shows it | features/queries |
| `query.listing` | `{net, listing}` a listing's reply ended (features/queries/listing.lua: STATS, TRACE, LIST and the rest), as a `hub.Listing`; the UI shows it | features/queries |
| `query.whowas` | `{net, whowas}` a WHOWAS reply ended, as a `hub.Whowas`; the UI shows it | features/queries |
| `query.accept` | `{net, accept}` the accept list came, as a `hub.AcceptList`; the UI shows it | features/queries |
| `eval.result` | `{value}` /eval returned values: `{code, n, ...}`, live; the UI shows them | commands/core |
| `notify.alert` | `{net, kind, text, beep?, flash?, color?}` something wants attention; the UI and notify decide how | features (snotice watches) |
