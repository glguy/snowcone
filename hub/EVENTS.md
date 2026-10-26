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
| `irc.message` | `{net, msg}` every inbound message outside a batch, after the model update | net/manager |
| `irc.sent` | `{net, msg}` outbound, secrets masked | net/send |
| `irc.batch` | `{net, type, params, messages}` when a batch closes | net/batch |
| `irc.nick` | `{net, old, new, self}` | net/handlers |
| `irc.isupport` | `{net, key, value}` value nil when removed, true without a value | net/irc |
| `snote` | `{net, name, server, time, timestamp, ...fields}` a parsed server notice | features/snotice |
| `snote.<name>` | the same event, by notice name | features/snotice |
| `notify.alert` | `{net, kind, text, beep?, flash?, colour?}` something wants attention; the UI and notify decide how | features (snotice watches) |

Planned by the design (section 4.3), not emitted yet:

| Topic | Payload | Emitted by |
| --- | --- | --- |
| `chat.message` | `{net, target, msg, mention, activity}` | features/chat |
