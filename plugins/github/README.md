# GitHub notification plugin for snowcone

This plugin (known on IRC as rutile) receives GitHub webhook notifications and announces them in IRC channels. It runs in `snowcone hub`.

## Installing

The plugin needs a Lua `json` module, for example `luarocks install luajson`.

Put `github.lua` and `github.events.txt` in the plugins directory, `~/.config/snowcone/plugins/` by default. Symlinks to this directory work. Then enable the plugin in `~/.config/snowcone/hub.toml` and name the network it works on:

```toml
[plugins]
modules = ['github']

[plugins.custom.github]
network = 'libera'
```

Run `/reload` to start it, and again after updating the plugin. `/plugins` shows any error from starting it. Click `[github]` there for the plugin's view, which lists the projects, their channels and how many events each announces.

## The webhook server

The plugin listens for HTTP on `[::1]` at port 8000. Change the port with `/gh_set_port <port>`; it takes effect at the next `/reload`. Put a reverse proxy such as nginx in front of it to accept requests from GitHub over HTTPS.

| Path | Answer |
|---|---|
| `POST /notify/<authid>` | A GitHub webhook delivery, signed with the secret of `<authid>` |
| `GET /` | A redirect to the rutile repository |
| `GET /robots.txt` | Disallows all crawlers |

## Setting up a project

1. Choose a name, the *authid*, and a secret for the webhook, then set them in the client:

   ```
   /gh_set_credential <authid> <secret>
   ```

2. Add the project (`owner/repository`, or an organization's login for organization webhooks), with the channel to announce in. The plugin joins the channel.

   ```
   /gh_add_project Libera-Chat/rutile #rutile
   /gh_authorize Libera-Chat/rutile <authid>
   ```

3. Choose the events to announce. A name is `<event>` or `<event>:<action>`, as listed in `github.events.txt`:

   ```
   /gh_event_on Libera-Chat/rutile push
   /gh_event_on Libera-Chat/rutile pull_request:opened
   ```

4. On GitHub, add a webhook to the repository or organization:
   - **Payload URL:** `https://<your proxy>/notify/<authid>`
   - **Content type:** `application/json`
   - **Secret:** the same secret

A delivery whose signature doesn't match its authid's secret is refused. So is one for a project that the authid isn't authorized for. Deliveries for unknown projects or events that aren't enabled are accepted and ignored. The status log shows what was announced or ignored, and why.

Supported events: `push` (including tags and force pushes), `issues`, `issue_comment`, `commit_comment`, `pull_request`, `pull_request_review`, `pull_request_review_comment`, `check_suite`, and `deploy` for r10k deployments.

## Client commands

| Command | Effect |
|---|---|
| `/gh_set_credential <authid> <secret>` | Set the webhook secret of an authid |
| `/gh_drop_credential <authid>` | Remove an authid and its authorizations |
| `/gh_add_project <repo> <channel>` | Add a project announced in a channel |
| `/gh_set_channel <repo> <channel>` | Change a project's channel |
| `/gh_drop_project <repo>` | Remove a project |
| `/gh_authorize <repo> <authid>` | Let an authid announce a project |
| `/gh_deauthorize <repo> <authid>` | Stop an authid announcing a project |
| `/gh_event_on <repo> <event>` | Announce an event for a project |
| `/gh_event_off <repo> <event>` | Stop announcing an event |
| `/gh_event_copy_from_to <from> <to>` | Copy one project's events to another |
| `/gh_set_port <port>` | Set the webhook port, used from the next `/reload` |
| `/gh_debug_on`, `/gh_debug_off` | Save each request body to `~/.cache/snowcone/gh-notify-<event>-<delivery>.json`, or stop |
| `/gh_replay <event> <file>` | Handle a saved request body again, from that directory |

## IRC commands

Staff (users whose host starts with `libera/staff/`) can send these to the plugin's nick in private message. Replies come as notices.

| Command | Effect |
|---|---|
| `help [command]` | List the commands, or explain one |
| `projects` | List the projects |
| `events <project>` | List the events a project announces |
| `list_events [search]` | List the valid event names, optionally only those containing `search` |
| `event_on <project> <event>` | Announce an event for a project |
| `event_off <project> <event>` | Stop announcing an event |
| `get_push_limit <project>` | Show how many lines one event may announce |
| `set_push_limit <project> <limit>` | Set it, from 1 to 20. A push announces its latest commit, then earlier commits up to the limit. |
| `mute [days=N] [hours=N] [project=P] [sender=S] [event=E] [pr=N] [issue=N]` | Stop announcing events that match every criterion given, for the days and hours given (added together) or until unmuted. `event` is the full name, such as `issues:opened`. |
| `mutes` | List the mutes, with their ids and time left |
| `unmute <id>` | Remove a mute |

## Saved data

Projects, credentials, mutes and the port are saved in `github.dat` in the plugins directory, as a Lua table. They are updated by the commands above, so editing the file by hand is rarely needed. If you do edit it, run `/reload` afterwards.
