# hub event topics

Every topic passed to `bus.emit` with a literal name is listed here;
`tests/hub/test-structure.lua` checks it. Events that relate to a network
carry `net`, the network id.

| Topic | Payload | Emitted by |
| --- | --- | --- |
| `app.reloaded` | `{generation, first}` after a generation becomes current | app |
| `app.quit` | `{}` before resources close and the client shuts down | app |
| `clock.tick` | `{now}` once a second, when the tick runs | app |
| `log` | `{category, text, time, timestamp}` for each log line | runtime/log |

Planned by the design (section 4.3), not emitted yet:

| Topic | Payload | Emitted by |
| --- | --- | --- |
| `net.state` | `{net, phase, prev, reason?}` | net/manager |
| `net.connected` | `{net, fingerprint}` | net/manager |
| `net.registered` | `{net, nick}` | net/registration |
| `net.closed` | `{net, reason}` | net/manager |
| `irc.message` | `{net, msg}` every inbound message, after the model update | net/handlers |
| `irc.sent` | `{net, msg}` outbound, secrets masked | net/send |
| `irc.batch` | `{net, type, params, messages}` | net/batch |
| `irc.nick` | `{net, old, new, self}` | net/handlers |
| `irc.isupport` | `{net, key, value}` | net/irc |
| `snote` | `{net, name, server, time, ...fields}` | features/snotice |
| `snote.<name>` | same payload, per notice name | features/snotice |
| `chat.message` | `{net, target, msg, mention, activity}` | features/chat |
| `notify.alert` | `{net, kind, text, beep?, flash?, colour?}` | any feature |
