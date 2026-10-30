-- Snowcone Plugin for Processing GitHub Events into IRC Notifications
--
-- This plugin processes GitHub webhook events and formats them into IRC notifications.
-- For more information on GitHub webhook events and payloads, visit:
-- https://docs.github.com/en/webhooks/webhook-events-and-payloads
--
-- A snowcone hub plugin. In the hub configuration:
--
--   [plugins]
--   modules = ['github']
--
--   [plugins.custom.github]
--   network = 'libera'   # where to announce and take staff commands
--
-- Projects, credentials, mutes and the port are saved in github.dat beside
-- the plugin; github.events.txt there lists the valid event names.
--
-- Author: Eric Mertens (glguy@libera.chat)
-- License: ISC
-- Copyright © 2024 Eric Mertens

--- @alias headers table<string, string>
--- @alias replacement (table<string, replacement>|string|number)

--#region IMPORTS

local file = require 'pl.file'
local json = require 'json'
local path = require 'pl.path'
local Set = require 'pl.Set'
local sha256 = myopenssl.get_digest 'sha256'
local tablex = require 'pl.tablex'

local repo_url = 'https://github.com/Libera-Chat/rutile'

local scrub_repls = {}
for i = 0, 0x1f do scrub_repls[string.char(i)] = utf8.char(0x2400 + i) end
scrub_repls['\x0a'] = '␤'
scrub_repls['\x7f'] = '␡'

--- Make control characters visible, so they can't format or break a line
--- @param str string
--- @return string
local function scrub(str)
    return (str:gsub('[\x00-\x1f\x7f]', scrub_repls))
end

--- Split a line into words separated by spaces
--- @param str string
--- @return string[]
local function split(str)
    local words = {}
    for word in str:gmatch '[^ ]+' do table.insert(words, word) end
    return words
end

--- Set when the plugin starts: the plugin api, the network to announce
--- on, the saved configuration and the set of valid event names
local api, net, config, all_events

--- Save the configuration so it survives restarts
--- @param new_config table
local function save_config(new_config)
    api.save(new_config)
end

--- Send a command to the configured network
local function send(command, ...)
    return api.send(net, command, ...)
end

--#endregion
--#region MESSAGE FORMATTING

--- Generates a hexadecimal representation of a hash from a given string.
--- @param bytes string The input string to be hashed.
--- @return string
local function hexbytes(bytes)
    local hex_representation = {}
    for i = 1, #bytes do
        hex_representation[i] = string.format('%02x', bytes:byte(i))
    end
    return table.concat(hex_representation)
end

--- Ensure that a string isn't longer than a given limit, truncate if needed
--- @param str string String to truncate
--- @param limit integer Maximum length in bytes of the kept text
--- @return string
local function truncate(str, limit)
    if #str > limit then
        -- cut before the UTF-8 character that byte `limit` belongs to
        local cut = limit
        while cut > 1 and str:byte(cut) & 0xC0 == 0x80 do
            cut = cut - 1
        end
        return str:sub(1, cut - 1) .. '…'
    else
        return str
    end
end

local function pretty_seconds(x)
    x = math.ceil(x / 60)

    if x <= 0 then return 'now' end
    local result = x%60 .. 'm'
    x = x // 60

    if x == 0 then return result end
    result = x%24 .. 'h' .. result
    x = x // 24

    if x == 0 then return result end
    return x .. 'd' .. result
end

--- Actions indicate a workflow has transitioned from closed to open
local resume_actions = Set{
    "reopened"
}

--- Actions that initiate a new workflow
local creation_actions = Set{
    "created", "opened", "commented"
}

--- Actions that end a workflow
local negative_actions = Set{
    "deleted", "closed", "removed"
}

--- Actions that indicate forward progress or completion of a workflow
local progress_actions = Set{
    "merged", "assigned", "resolved", "pushed", "approved"
}

--- Actions that should draw special attention
local important_actions = Set{
    "force pushed"
}

--- Render actions seen in GitHub API into IRC formatted strings
--- @param action string Action name
--- @return string text IRC-formatted, human-readable text
local function format_action(action)
    action = action:gsub('_', ' ')
    if progress_actions[action] then
        return '\x02\x0302' .. action .. '\x0f'
    elseif creation_actions[action] then
        return '\x02\x0303' .. action .. '\x0f'
    elseif negative_actions[action] then
        return '\x02\x0304' .. action .. '\x0f'
    elseif important_actions[action] then
        return '\x02\x0308' .. action .. '\x0f'
    elseif resume_actions[action] then
        return '\x02\x0306' .. action .. '\x0f'
    else
        return '\x02' .. action .. '\x0f'
    end
end

local function format_conclusion(conclusion)
    local messages = {
        success = '\x02\x0303success\x0f',
        failure = '\x02\x0304failure\x0f',
        neutral = '\x02neutral\x0f',
        cancelled = '\x02cancelled\x0f',
        timed_out = '\x02\x0304timed out\x0f',
        action_required = '\x02action required\x0f',
        stale = '\x02stale\x0f',
    }
    return messages[conclusion] or conclusion
end

--- Render a truncated commit ID
--- @param str string
--- @return string
local function format_commit_id(str)
    return '\x1d' .. str:sub(1,9) .. '\x0f'
end

--- Given a replacement and an interpolation string evaluate all of the
--- interpolation placeholders.
---
--- Placeholders format: '{' '#'? ('.' <field name>)* '}'
--- Leading '#' uses raw replacement, otherwise control characters are replaced.
--- Each '.' <field name> causes the replacement value to be indexed.
--- Final replacement values are converted to string and truncated.
---
--- @param obj replacement Replacements
--- @param str string Format string
--- @return string
local function interpolate(obj, str)
    return (str:gsub('{(#?%.[._%a]*)}', function(expr)
        local cursor, raw, rest = obj, expr:match '^(#?)(.*)$'
        while rest ~= '' do
            local key
            key, rest = rest:match '^%.([_%a]*)(.*)$'
            cursor = cursor[key]
            if cursor == nil then
                error ('bad interpolation {' .. expr .. '} in: ' .. str)
            end
        end
        cursor = tostring(cursor)
        if raw == '' then
            -- trim and consolidate whitespace, truncate, scrub controls
            return scrub(truncate(cursor:gsub('%s+', ' '):match('^ ?(.-) ?$'), 100))
        end
        return cursor
    end))
end

local function match_rule(rule, event, body)
    for name, value in pairs(rule) do
        local thing
        if 'project' == name then
            thing = body.repository and body.repository.full_name
                 or body.organization and body.organization.login
        elseif 'sender' == name then
            thing = body.sender and body.sender.login
        elseif 'event' == name then
            thing = event
        elseif 'pr' == name then
            -- comments on a PR's conversation arrive as issue_comment
            thing = body.pull_request and body.pull_request.number
                 or body.issue and body.issue.pull_request and body.issue.number
        elseif 'issue' == name then
            thing = body.issue and body.issue.number
        end
        if thing ~= value then return false end
    end
    return true
end

local common_prefix = '[{.repository.owner.login}/\x02{.repository.name}\x02] '
local action_prefix = common_prefix .. '\x02{.sender.login}\x02 {#.x_action} '

--- Functions for generating an announcement message for each supported event type
--- @type table<string, fun(body: table): string[]?>
local formatters = {
    push = function(body)
        if not body.head_commit then
            return
        end

        local n = #body.commits
        -- a tag, or a new branch at an existing commit, brings no commits
        local summary_commit = n > 0 and body.commits[n] or body.head_commit

        local target = body.ref:match('^refs/heads/(.*)$')
        if not target then
            target = body.ref:match('^refs/tags/(.*)$')
            if target then
                target = 'tag ' .. target
            end
        end

        if target then
            body.x_target = target
            body.x_after = format_commit_id(body.after)
            body.x_action = format_action(body.forced and 'force pushed' or 'pushed')
            body.x_summary = summary_commit.message:match('^%s*([^\r\n]*)')

            local messages
            if n == 0 then
                messages = {interpolate(body,
                    action_prefix .. '\x0302{.x_target}\x0f {#.x_after}: {.x_summary} - \x0308{#.compare}')}
            else
                body.x_n = n == 1 and '1 commit' or n .. ' commits'
                messages = {interpolate(body,
                    action_prefix .. '{#.x_n} to \x0302{.x_target}\x0f {#.x_after}: {.x_summary} \z
                    - \x0308{#.compare}')}
            end

            for i = n-1, 1, -1 do
                local repl = {
                    x_id = format_commit_id(body.commits[i].id),
                    x_summary = body.commits[i].message:match('^%s*([^\r\n]*)')
                }
                table.insert(messages, interpolate(repl, '... {#.x_id}: {.x_summary}'))
            end

            return messages
        end
    end,

    issue_comment = function(body)
        body.x_kind = body.issue.pull_request and 'PR' or 'issue' -- PRs are a special kind of issue.
        if body.action == 'created' then
            body.x_action = format_action('commented')
            return {interpolate(body,
                action_prefix .. 'on {#.x_kind} #{#.issue.number} ({.issue.title}): \z
                {.comment.body} - \x0308{#.comment.html_url}')}
        else
            body.x_action = format_action(body.action)
            return {interpolate(body,
                action_prefix .. 'comment on {#.x_kind} #{#.issue.number} ({.issue.title}): \z
                {.comment.body} - \x0308{#.comment.html_url}')}
        end
    end,

    commit_comment = function(body)
        body.x_commit_id = format_commit_id(body.comment.commit_id)
        if body.action == 'created' then
            body.x_action = format_action('commented')
            return {interpolate(body,
                action_prefix .. 'on commit {#.x_commit_id}: {.comment.body} - \x0308{#.comment.html_url}')}
        else
            body.x_action = format_action(body.action)
            return {interpolate(body,
                action_prefix .. 'comment on commit {#.x_commit_id}: {.comment.body} - \x0308{#.comment.html_url}')}
        end
    end,

    issues = function(body)
        if body.action == 'closed' and body.issue.state_reason == 'completed' then
            body.x_action = format_action('resolved')
        else
            body.x_action = format_action(body.action)
        end
        return {interpolate(body,
            action_prefix .. 'issue #{#.issue.number}: \x02{.issue.title}\x02 - \x0308{#.issue.html_url}')}
    end,

    pull_request_review = function(body)
        if body.action == 'submitted' and body.review.state == 'approved' then
            body.x_action = format_action('approved')
            if body.review.body then
                return {interpolate(body,
                    action_prefix .. 'PR #{#.pull_request.number} ({.pull_request.title}): \z
                    {.review.body} - \x0308{#.review.html_url}')}
            else
                return {interpolate(body,
                    action_prefix .. 'PR #{#.pull_request.number} ({.pull_request.title}) \z
                    - \x0308{#.review.html_url}')}
            end
        else
            body.x_action = format_action(body.action)
            if body.review.body then
                return {interpolate(body,
                    action_prefix .. 'review on \z
                    PR #{#.pull_request.number} ({.pull_request.title}): {.review.body} - \x0308{#.review.html_url}')}
            else
                return {interpolate(body,
                    action_prefix .. 'review on \z
                    PR #{#.pull_request.number} ({.pull_request.title}) - \x0308{#.review.html_url}')}
            end
        end
    end,

    pull_request_review_comment = function(body)
        if body.action == 'created' then
            body.x_action = format_action('commented')
            return {interpolate(body,
                action_prefix .. 'on PR #{#.pull_request.number} ({.pull_request.title}): \z
                {.comment.body} - \x0308{#.comment.html_url}')}
        else
            body.x_action = format_action(body.action)
            return {interpolate(body,
                action_prefix .. 'comment on PR #{#.pull_request.number} ({.pull_request.title}): \z
                {.comment.body} - \x0308{#.comment.html_url}')}
        end
    end,

    pull_request = function(body)
        if body.action == 'closed' and body.pull_request.merged then
            body.x_action = format_action('merged')
        else
            body.x_action = format_action(body.action)
        end
        return {interpolate(body,
            action_prefix .. 'PR #{#.pull_request.number}: {.pull_request.title} - \x0308{#.pull_request.html_url}')}
    end,

    check_suite = function(body)
        local top_pr = body.check_suite.pull_requests[1]
        body.x_commit_id = format_commit_id(body.check_suite.head_sha)
        if top_pr then
            body.x_target = interpolate(top_pr, "PR #{#.number}")
        elseif body.head_branch then
            body.x_target = interpolate(body, '\x0302{.head_branch}\x0f')
        else
            body.x_target = 'commit'
        end

        if body.action == 'completed' then
            body.x_action = format_conclusion(body.check_suite.conclusion)
        else
            body.x_action = format_action(body.action)
        end
        return {interpolate(body,
            common_prefix .. 'Check suite \x02{.check_suite.app.name}\x02 for {#.x_target} \z
            {#.x_commit_id}: {#.x_action}')}
    end,

    -- Special event for r10k deployments
    deploy = function(body)
        local _, count = body.environment:gsub(" ", "")
        body.x_count = count > 1 and (count .. " environments") or "1 environment"
        return {interpolate(body,
            common_prefix .. '{#.x_count} \x02\x0302deployed\x0f: \x02{.environment}\x02')}
    end,
}

--#endregion
--#region FILESYSTEM HELPERS

--- Compute the application's cache directory respecting XDG conventions
--- @return string path cache directory path
local function cache_dir()
    local xdg_cache_home = os.getenv 'XDG_CACHE_HOME'
    if xdg_cache_home ~= nil and xdg_cache_home ~= '' then
        return path.join(xdg_cache_home, 'snowcone')
    end
    local home = assert(os.getenv 'HOME')
    return path.join(home, '.cache', 'snowcone')
end

--#endregion
--#region HTTP LOGIC
--#region HTTP REPLIES

local plain_text_headers = {['Content-Type'] = 'text/plain'}

local function reply_ok(body)
    return 200, body, plain_text_headers
end

local function reply_no_content()
    return 204, '', plain_text_headers
end

local function reply_found(location)
    return 302, 'document at ' .. location, {Location = location, ["Content-Type"] = "text/plain"}
end

local function reply_bad_request()
    return 400, 'bad request', plain_text_headers
end

local function reply_unauthorized()
    return 401, 'unauthorized', plain_text_headers
end

local function reply_forbidden()
    return 403, 'forbidden', plain_text_headers
end

local function reply_not_found()
    return 404, 'not found', plain_text_headers
end

local function reply_method_not_allowed()
    return 405, 'method not allowed', plain_text_headers
end

--#endregion

--- Process a raw JSON body as a GitHub notification.
--- @param authid string? Authentication identifier or nil to bypass check
--- @param delivery string? UUID for event
--- @param event string Event name
--- @param raw_body string JSON encoded object
--- @return number status HTTP response status code
--- @return string body HTTP response body
--- @return headers headers HTTP response headers
local function do_notify(authid, delivery, event, raw_body)
    -- simple mode decodes null as nil, so an absent field and a null one
    -- are the same (luajson's default gives a sentinel, which is truthy)
    local body = json.decode(raw_body, json.decode.simple)
    local full_name = body.repository and body.repository.full_name
                   or body.organization and body.organization.login
    if not full_name then
        api.log('Ignoring %s: no repository or organization', event)
        return reply_no_content()
    end
    local project = config.projects[full_name]

    if authid and project and not project.authorized[authid] then
        return reply_forbidden()
    end

    -- Save body for debugging and replay, but delay saving the event until we've checked it's valid
    if config.debug and delivery then
        local filename = path.join(cache_dir(), 'gh-notify-' .. event .. '-' .. delivery .. '.json')
        local ok, err = file.write(filename, raw_body)
        if not ok then
            api.log('Saving %s failed: %s', filename, err)
        end
    end

    -- <event> or <event>:<action>
    local full_event = event
    if body.action then
        full_event = full_event .. ':' .. body.action
    end

    -- If a message is called for, store it here
    local messages
    if project and project.events[full_event] then
        local formatter = formatters[event]
        if not formatter then
            api.log('Error: No formatter for enabled event: %s', event)
            return reply_no_content()
        end

        for mute_id, mute in pairs(config.mutes) do
            if mute.expire and mute.expire <= os.time() then
                config.mutes[mute_id] = nil
                save_config(config)
                api.log('Mute %d expired', mute_id)
            elseif match_rule(mute.rule, full_event, body) then
                api.log('Skipping %s %s due to mute %d', full_name, full_event, mute_id)
                return reply_no_content()
            end
        end

        messages = formatter(body)
    end

    if messages then
        local n = math.min(project.push_limit, #messages)
        for i = 1, n do
            local ok, err = pcall(send, 'NOTICE', project.channel, messages[i])
            if not ok then
                api.log('Announcement to %s failed: %s', project.channel, err)
                break
            end
        end
        api.log('Announcing %s %s %s', full_name, full_event, project.channel)
    else
        api.log('Ignoring %s %s', full_name, full_event)
    end
    return reply_no_content()
end

--- Map of target patterns to response handler functions.
--- Each handler expects: HTTP headers, HTTP method, HTTP body, pattern matches...
--- @type table<string, fun(headers: headers, method: string, body: string, ...: string): number, string, headers>
local routes = {
    ['^/notify/(.*)$'] = function(headers, method, body, notify_name)
        if method ~= 'POST' then
            return reply_method_not_allowed()
        end

        local event = headers['x-github-event']
        local delivery = headers['x-github-delivery']
        local signature = headers['x-hub-signature-256']

        if not delivery then
            delivery = hexbytes(sha256:digest(body))
        end

        if not (event and signature) then
            return reply_bad_request()
        end

        local secret = config.credentials[notify_name]
        if not (secret and signature == 'sha256=' .. hexbytes(sha256:hmac(body, secret))) then
            return reply_unauthorized()
        end

        return do_notify(notify_name, delivery, event, body)
    end,

    ['^/$'] = function(_, method)
        if method ~= 'GET' then
            return reply_method_not_allowed()
        end
        return reply_found(repo_url)
    end,

    ['^/robots.txt$'] = function(_, method)
        if method ~= 'GET' then
            return reply_method_not_allowed()
        end
        return reply_ok('User-agent: *\nDisallow: /\n')
    end,
}

--- Callback logic for an httpd event
--- @param method? string HTTP request method or nil
--- @param target string HTTP request path or error kind
--- @param body string HTTP request body or error message
--- @param headers? headers HTTP request headers or nil
--- @return number? status HTTP reponse status
--- @return string? body HTTP response bode
--- @return headers? headers HTTP response headers
local function on_http(method, target, body, headers)

    -- No method means target:error_kind body:error_message
    if method == nil then
        api.log('http error: %s %s', target, body)
        return
    end

    for pattern, handler in pairs(routes) do
        local matches = {target:match(pattern)}
        if next(matches) then
            local result, code, rbody, rheaders = pcall(handler, headers or {}, method, body, table.unpack(matches))
            if result then
                return code, rbody, rheaders
            else
                api.log('handler error: %s', code)
                return 500, 'internal server error', plain_text_headers
            end
        end
    end

    return reply_not_found()
end

--#endregion
--#region IRC LOGIC

--- Break up the keys of a table into multiple lines trying to keep them under 400 characters long
--- @param tab table Table whose keys are enumerated
--- @param prefix string? Prefix to add to first line of output
--- @param sep string? Element separator defaulting to space
--- @return string[] lines
local function keys_as_lines(tab, prefix, sep)
    local lines = {}
    local acc = {}
    local n = 0

    if prefix then
        table.insert(acc, prefix)
        n = #prefix
    end

    for name in tablex.sort(tab) do
        if next(acc) and #name + 1 + n > 400 then
            table.insert(lines, table.concat(acc, sep or ' '))
            acc = {}
            n = 0
        end

        table.insert(acc, name)
        n = n + #name
    end

    if next(acc) then
        table.insert(lines, table.concat(acc, sep or ' '))
    end

    return lines
end

--- Issue a JOIN command for the channels we need to be able to announce in.
--- The server ignores a JOIN for a channel we're already in.
local function join_channels()
    local channels = {}
    for _, project in pairs(config.projects) do
        channels[project.channel] = true
    end

    for _, line in ipairs(keys_as_lines(channels, nil, ',')) do
        send('JOIN', line)
    end
end

--- Why an event name can't be announced, or nil when it can
--- @param event string <event> or <event>:<action>
--- @return string?
local function event_problem(event)
    -- Check that the event is in the GitHub API
    if not all_events[event] then
        return 'Unknown event'
    end

    -- Check if we have a formatter for this event
    local prefix = event:match '^[^:]*'
    if not formatters[prefix] then
        return 'Event not yet implemented'
    end
end

--- All the online documentation content
--- @type table<string, string[]>
local help_strings = {
    projects = {'projects - List all of the configured project names'},
    events = {'events <\x1fproject\x0f> - List all of the configured events for the project'},
    event_on = {'event_on <\x1fproject\x0f> <\x1fevent\x0f>[:<\x1faction\x0f>] \z
                - Start announcing an event for a project'},
    event_off = {'event_off <\x1fproject\x0f> <\x1fevent\x0f>[:<\x1faction\x0f>] \z
                - Stop announcing an event for a project'},
    list_events = {'list_events [\x1fsearch\x0f] - list all valid event names optionally filtered search term'},
    help = {'help [\x1fcommand\x0f] - Print help for a command or list the available commands'},
    mute = {'mute [days=\x1fdays\x0f] [hours=\x1fhours\x0f] \z
                  [project=\x1fproject\x0f] [sender=\x1fsender\x0f] \z
                  [event=\x1fevent\x0f] \z
                  [pr=\x1fpr\x0f] [issue=\x1fissue\x0f] - add a mute'},
    unmute = {'unmute <\x1fid\x0f> - delete a mute'},
    mutes = {'mutes - list current mutes'},
    get_push_limit = {'get_push_limit <repo> - get maximum number of messages per event'},
    set_push_limit = {'set_push_limit <repo> <limit> - set maximum number of messages per event'},
}

--- Commands available to staff members chatting with the bot in private message
local irc_commands = {
    --- List all the commands or provide help text for a specific command
    --- @type fun(command: string?): string[]
    help = function(command)
        if command then command = command:lower() end
        local doc = help_strings[command]
        if doc then
            return doc
        else
            return keys_as_lines(help_strings, 'Commands:')
        end
    end,

    --- List all the events available to be announced
    --- @type fun(search: string): string[]
    list_events = function(search)
        local events
        if search then
            events = {}
            for event in pairs(all_events) do
                if event:find(search, 1, true) then
                    events[event] = true
                end
            end
        else
            events = all_events
        end
        return keys_as_lines(events, 'Events:')
    end,

    --- Enable reporting an event for a specific repository
    --- @type fun(repo: string, event: string): string[]
    event_on = function(repo, event)

        local project = config.projects[repo]
        if not project then
            return {'No such project'}
        end

        local problem = event_problem(event)
        if problem then
            return {problem}
        end

        local old = project.events[event]
        if old then
            return {'Event already enabled'}
        end

        project.events[event] = true
        save_config(config)
        return {'Event enabled'}
    end,

    --- Disable reporting an event for a specific repository
    --- @type fun(repo: string, event: string): string[]
    event_off = function(repo, event)
        local project = config.projects[repo]
        if not project then
            return {'No such project'}
        end

        -- Check that the event is in the GitHub API
        if not all_events[event] then
            return {'Unknown event'}
        end

        local old = project.events[event]
        if not old then
            return {'Event already disabled'}
        end

        project.events[event] = nil
        save_config(config)
        return {'Event disabled'}
    end,

    --- List all the configured projects
    --- @type fun(): string[]
    projects = function()
        return keys_as_lines(config.projects, 'Projects:')
    end,

    --- List all the events enabled for a particular project
    --- @type fun(repo: string): string[]
    events = function(repo)
        local project = config.projects[repo]
        if not project then
            return {'no such project'}
        end
        return keys_as_lines(project.events, 'Events:')
    end,

    mute = function(...)
        local mute = { rule = {} }
        local seconds = 0

        for _, arg in ipairs({...}) do
            local k, v = arg:match('^([^ ]+)=([^ ]+)$')
            if not k then
                return {'Syntax error near: ' .. arg}
            end
            k = k:lower()
            if 'days' == k then
                local days = tonumber(v)
                if not days then
                    return {'Bad days: ' .. v}
                end
                seconds = seconds + days * 24 * 60 * 60
            elseif 'hours' == k then
                local hours = tonumber(v)
                if not hours then
                    return {'Bad hours: ' .. v}
                end
                seconds = seconds + hours * 60 * 60
            elseif 'sender' == k then
                mute.rule.sender = v
            elseif 'project' == k then
                if not config.projects[v] then
                    return {'Unknown project: ' .. v}
                end
                mute.rule.project = v
            elseif 'event' == k then
                mute.rule.event = v
            elseif 'pr' == k then
                mute.rule.pr = math.tointeger(v)
                if not mute.rule.pr then
                    return {'Bad pr: ' .. v}
                end
            elseif 'issue' == k then
                mute.rule.issue = math.tointeger(v)
                if not mute.rule.issue then
                    return {'Bad issue: ' .. v}
                end
            else
                return {'Unknown parameter: ' .. k}
            end
        end

        if not next(mute.rule) then
            return {'No criteria specified'}
        end

        if seconds > 0 then
            mute.expire = os.time() + seconds
        end

        local mute_id = config.next_mute
        config.next_mute = mute_id + 1
        config.mutes[mute_id] = mute
        save_config(config)

        return {'Added mute ' .. mute_id}
    end,

    unmute = function(id)
        if config.mutes[tonumber(id)] then
            config.mutes[tonumber(id)] = nil
            save_config(config)
            return {'Removed mute'}
        else
            return {'Mute not found'}
        end
    end,

    mutes = function()
        if not next(config.mutes) then
            return {'No mutes'}
        end

        local result = {}
        local i = 0
        for mute_id, mute in tablex.sort(config.mutes) do
            i = i + 1
            local line = '\x02' .. mute_id .. '\x0f:'
            local rule = mute.rule
            if mute.expire  then line = line .. ' expire=\x02' .. pretty_seconds(mute.expire - os.time()) .. '\x0f' end
            if rule.project then line = line .. ' project=\x02' .. rule.project .. '\x0f' end
            if rule.sender  then line = line .. ' sender=\x02'  .. rule.sender  .. '\x0f' end
            if rule.event   then line = line .. ' event=\x02'   .. rule.event   .. '\x0f' end
            if rule.issue   then line = line .. ' issue=\x02'   .. rule.issue   .. '\x0f' end
            if rule.pr      then line = line .. ' pr=\x02'      .. rule.pr      .. '\x0f' end
            result[i] = line
        end
        return result
    end,

    set_push_limit = function(repo, limit)
        local project = config.projects[repo]
        if not project then
            return {'no such project'}
        end

        limit = math.tointeger(limit)
        if not limit then
            return {'invalid limit argument'}
        end

        if limit < 1 or 20 < limit then
            return {'limit argument out of bounds'}
        end

        project.push_limit = limit
        save_config(config)
        return {'Push limit for ' .. repo .. ' is now ' .. project.push_limit}
    end,

    get_push_limit = function(repo)
        local project = config.projects[repo]
        if not project then
            return {'no such project'}
        end
        return {'Push limit for ' .. repo .. ' is ' .. project.push_limit}
    end,
}

--- Answer a staff member's command sent in private message
--- @param msg table PRIVMSG
local function on_privmsg(msg)
    -- Only accept commands from staff
    if not (msg.host and msg.host:match('^libera/staff/')) then return end

    -- Only accept direct messages, not those to a channel
    if msg[1]:match '^[@+]*[#&]' then return end

    local args = split(msg[2])
    local handler = args[1] and irc_commands[args[1]:lower()]
    if handler then
        local reply = handler(table.unpack(args, 2))
        for _, line in ipairs(reply) do
            send('NOTICE', msg.nick, line)
        end
    end
end

--#endregion
--#region IN-CLIENT COMMANDS

--- Commands typed in the client: name = {spec, usage, help, fn(...)}
local client_commands = {
    gh_replay = {'$g $g', 'event file', 'Replay an event from a request body saved in debug mode',
        function(event, name)
            do_notify(nil, nil, event, file.read(path.join(cache_dir(), name)))
        end},

    gh_debug_on = {'', nil, 'Save request bodies for inspection and replay', function()
        config.debug = true
        save_config(config)
    end},

    gh_debug_off = {'', nil, 'Stop saving request bodies', function()
        config.debug = false
        save_config(config)
    end},

    gh_set_credential = {'$g $g', 'authid secret', 'Set the webhook secret of a notify name',
        function(authid, secret)
            config.credentials[authid] = secret
            save_config(config)
        end},

    gh_drop_credential = {'$g', 'authid', 'Remove a webhook secret and its authorizations', function(authid)
        if not config.credentials[authid] then
            error('no such credential', 0)
        end
        config.credentials[authid] = nil
        for _, project in pairs(config.projects) do
            project.authorized[authid] = nil
        end
        save_config(config)
    end},

    gh_authorize = {'$g $g', 'repo authid', 'Let a notify name announce a project', function(repo, authid)
        local project = config.projects[repo]
        if not project then
            error('no such project', 0)
        end
        if not config.credentials[authid] then
            error('no such authid', 0)
        end
        project.authorized[authid] = true
        save_config(config)
    end},

    gh_deauthorize = {'$g $g', 'repo authid', 'Stop a notify name announcing a project', function(repo, authid)
        local project = config.projects[repo]
        if not project then
            error('no such project', 0)
        end
        project.authorized[authid] = nil
        save_config(config)
    end},

    gh_add_project = {'$g $g', 'repo channel', 'Add a project announced in a channel', function(repo, channel)
        if config.projects[repo] then
            error('project exists', 0)
        end
        config.projects[repo] = {
            channel = channel,
            authorized = {},
            events = {},
            push_limit = 1,
        }
        save_config(config)
        join_channels()
    end},

    gh_set_channel = {'$g $g', 'repo channel', "Change a project's channel", function(repo, channel)
        if not config.projects[repo] then
            error('no such project', 0)
        end
        config.projects[repo].channel = channel
        save_config(config)
        join_channels()
    end},

    gh_drop_project = {'$g', 'repo', 'Remove a project', function(repo)
        if not config.projects[repo] then
            error('no such project', 0)
        end
        config.projects[repo] = nil
        save_config(config)
    end},

    gh_event_on = {'$g $g', 'repo event[:action]', 'Announce an event for a project', function(repo, event)
        if not config.projects[repo] then
            error('no such project', 0)
        end
        local problem = event_problem(event)
        if problem then
            error(problem, 0)
        end
        config.projects[repo].events[event] = true
        save_config(config)
    end},

    gh_event_off = {'$g $g', 'repo event[:action]', 'Stop announcing an event', function(repo, event)
        if not config.projects[repo] then
            error('no such project', 0)
        end
        config.projects[repo].events[event] = nil
        save_config(config)
    end},

    --- Short-cut when setting up a new project to copy the settings of a previous project
    gh_event_copy_from_to = {'$g $g', 'from to', "Copy one project's events to another",
        function(repo_src, repo_dst)
            local src = config.projects[repo_src]
            if not src then
                error('no such source project', 0)
            end

            local dst = config.projects[repo_dst]
            if not dst then
                error('no such destination project', 0)
            end

            dst.events = tablex.copy(src.events)
            save_config(config)
        end},

    gh_set_port = {'$i', 'port', 'Set the webhook port, used from the next reload', function(port)
        if port <= 0 or port > 65535 then
            error('bad port number', 0)
        end
        config.port = port
        save_config(config)
    end},
}

--#endregion
--#region STARTUP SEQUENCE

--- @param plugin_api table the hub plugin api
return function(plugin_api)
    api = plugin_api
    net = api.config.network
    if not net then
        error('set the network to announce on in [plugins.custom.github] network', 0)
    end

    -- Install a default configuration if one doesn't exist
    config = api.load() or {}
    if not config.debug         then config.debug       = false end
    if not config.projects      then config.projects    = {}    end
    if not config.credentials   then config.credentials = {}    end
    if not config.port          then config.port        = 8000  end
    if not config.mutes         then config.mutes       = {}    end
    if not config.next_mute     then config.next_mute   = 1     end
    save_config(config)

    -- Populate a set of all the valid event names
    all_events = {}
    for event in io.lines(api.path 'events.txt') do
        all_events[event] = true
    end

    api.on('irc.message', function(ev)
        if ev.net == net and ev.msg.command == 'PRIVMSG' then
            on_privmsg(ev.msg)
        end
    end)

    -- Join channels when we transition to a connected state
    api.on('net.registered', function(ev)
        if ev.net == net then join_channels() end
    end)

    for name, command in pairs(client_commands) do
        local spec, usage, help, fn = table.unpack(command, 1, 4)
        api.command(name, spec, function(_, ...) return fn(...) end, help, usage)
    end

    api.view('github', {
        render = function(_, win)
            ncurses.colorset(ncurses.COLOR_BLUE, nil, win)
            win:waddstr('    Project                                  Channel              Events\n')
            ncurses.attrset(ncurses.WA_NORMAL, 0, win)
            for key, project in tablex.sort(config.projects) do
                win:waddstr(string.format('    %-40s %-20s %d\n', key, project.channel, tablex.size(project.events)))
            end
        end,
    })

    -- The previous generation's listener is closed before this one starts
    api.httpd('::1', config.port, on_http)

    -- When the plugin (re)loads and we're already connected then
    -- make sure we're in all the right channels.
    pcall(join_channels)
end

--#endregion
