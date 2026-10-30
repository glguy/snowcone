-- The GitHub plugin (plugins/github) driven through hub: webhook requests
-- straight to its httpd handler, IRC through a fake transport, and client
-- commands through the command line. Needs a Lua json module; without one
-- the run exits with 77, which ctest reports as skipped.
--
-- Run with:  snowcone tests/hub/test-github.lua

if not pcall(require, 'json') then
    print('1..0 # SKIP no json module')
    os.exit(77)
end

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')
local fake_ncurses = dofile(here .. '/fake_ncurses.lua')
local file = require 'pl.file'
local path = require 'pl.path'
local pretty = require 'pl.pretty'

fake_ncurses.install(120, 40)

-- The plugin and its event list in a directory of their own, so its saved
-- data stays out of the source tree
local source = path.join(here, '..', '..', 'plugins', 'github')
local dir = os.tmpname()
os.remove(dir)
path.mkdir(dir)
for _, name in ipairs {'github.lua', 'github.events.txt'} do
    assert(file.write(path.join(dir, name), assert(file.read(path.join(source, name)))))
end
local dat = path.join(dir, 'github.dat')

local REPO = 'Libera-Chat/rutile'
local SECRET = 'secret'

local function saved()
    return pretty.read(assert(file.read(dat)))
end

-- Boot hub with the plugin and one network, registered; returns the
-- connection and the httpd handler
local function boot(projects)
    assert(file.write(dat, pretty.write {
        credentials = {gh = SECRET, other = 'other secret'},
        projects = projects or {
            [REPO] = {
                channel = '#rutile',
                authorized = {gh = true},
                events = {
                    push = true,
                    ['issues:opened'] = true,
                    ['issue_comment:created'] = true,
                    ['pull_request:opened'] = true,
                    ['pull_request_review:submitted'] = true,
                },
                push_limit = 2,
            },
        },
        mutes = {},
        next_mute = 1,
        port = 8123,
    }))

    local real = snowcone.start_httpd
    local listener
    snowcone.start_httpd = function(host, port, cb)
        listener = {host = host, port = port, cb = cb}
        return {close = function() end}
    end
    local fake = FakeTransport.new()
    local ok, err = pcall(T.boot, {ui = true, transport = fake, config = {
        plugins = {directory = dir, modules = {'github'}, custom = {github = {network = 'libera'}}},
        networks = {{id = 'libera', server = {host = 'h', port = 1}, identity = {nick = 'me'}, features = {}}},
    }})
    snowcone.start_httpd = real
    if not ok then error(err, 0) end

    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 376 me :End of MOTD'
    return c, listener
end

local function hex(bytes)
    return (bytes:gsub('.', function(ch) return string.format('%02x', ch:byte()) end))
end
local sha256 = myopenssl.get_digest 'sha256'

-- A JSON object from Lua values: strings, numbers, booleans, json_null,
-- arrays (tables with [1]) and objects
local json_null = {}
local function to_json(v)
    if v == json_null then return 'null' end
    local kind = type(v)
    if kind == 'string' then return (string.format('%q', v):gsub('\\\n', '\\n')) end
    if kind ~= 'table' then return tostring(v) end
    local parts = {}
    if v[1] ~= nil or next(v) == nil and getmetatable(v) == 'array' then
        for _, x in ipairs(v) do table.insert(parts, to_json(x)) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, x in pairs(v) do table.insert(parts, string.format('%q:%s', k, to_json(x))) end
    return '{' .. table.concat(parts, ',') .. '}'
end
local function array(t) return setmetatable(t, {__metatable = 'array'}) end

local function payload(fields)
    local body = {
        repository = {full_name = REPO, name = 'rutile', owner = {login = 'Libera-Chat'}},
        sender = {login = 'glguy'},
    }
    for k, v in pairs(fields) do body[k] = v end
    return to_json(body)
end

-- Deliver a webhook signed for an authid; returns the status
local function deliver(listener, event, body, authid, secret)
    local signature = 'sha256=' .. hex(sha256:hmac(body, secret or SECRET))
    return (listener.cb('POST', '/notify/' .. (authid or 'gh'), body, {
        ['x-github-event'] = event,
        ['x-github-delivery'] = 'delivery-1',
        ['x-hub-signature-256'] = signature,
    }))
end

local function push(fields)
    local body = {
        ref = 'refs/heads/main', after = '0123456789abcdef', forced = false,
        compare = 'https://example.test/compare',
        head_commit = {id = '0123456789abcdef', message = 'head'},
        commits = array {},
    }
    for k, v in pairs(fields or {}) do body[k] = v end
    return payload(body)
end

-- Strip IRC formatting, to compare announcements as text
local function plain(line)
    return (line:gsub('\x03%d%d?', ''):gsub('[\x02\x0f\x1d\x1f]', ''))
end

local function plain_all(lines)
    local out = {}
    for i, line in ipairs(lines) do out[i] = plain(line) end
    return out
end

-- Send a private message from a staff member; returns the replies
local function staff(c, text, target)
    c:recv(':staffer!u@libera/staff/staffer PRIVMSG ' .. (target or 'me') .. ' :' .. text)
    return plain_all(c:take())
end

local function command(text)
    T.require 'hub.ui.cmdline'.execute(text)
end

T.case('starts on the saved port and joins the project channels', function()
    local c, listener = boot()
    T.eq({listener.host, listener.port}, {'::1', 8123}, 'listener')
    local joined = false
    for _, line in ipairs(c:take()) do
        if line == 'JOIN #rutile' then joined = true end
    end
    T.ok(joined, 'joined at registration')
end)

T.case('requests are checked before anything is announced', function()
    local c, listener = boot()
    c:take()
    local body = push()
    T.eq(deliver(listener, 'push', body, 'gh', 'wrong'), 401, 'bad signature')
    T.eq(deliver(listener, 'push', body, 'nobody'), 401, 'unknown authid')
    T.eq(deliver(listener, 'push', body, 'other', 'other secret'), 403, 'authid not authorized for the project')
    T.eq(listener.cb('POST', '/notify/gh', body, {}), 400, 'missing headers')
    T.eq(listener.cb('GET', '/notify/gh', '', {}), 405, 'GET on notify')
    T.eq(listener.cb('GET', '/', '', {}), 302, 'root redirects')
    T.eq(listener.cb('GET', '/robots.txt', '', {}), 200, 'robots.txt')
    T.eq(listener.cb('GET', '/elsewhere', '', {}), 404, 'unknown path')
    T.eq(c:take(), {}, 'nothing announced')
end)

T.case('pushes announce up to the push limit', function()
    local c, listener = boot()
    c:take()
    T.eq(deliver(listener, 'push', push {commits = array {
        {id = 'aaaaaaaaaaaa', message = 'first\nbody'},
        {id = 'bbbbbbbbbbbb', message = 'second'},
        {id = 'cccccccccccc', message = 'third'},
    }}), 204, 'accepted')
    T.eq(plain_all(c:take()), {
        'NOTICE #rutile :[Libera-Chat/rutile] glguy pushed 3 commits to main 012345678: third'
            .. ' - https://example.test/compare',
        'NOTICE #rutile :... bbbbbbbbb: second',
    }, 'head commit, then earlier ones up to the limit')
end)

T.case('a tag or a branch at an existing commit has no commits', function()
    local c, listener = boot()
    c:take()
    T.eq(deliver(listener, 'push', push {ref = 'refs/tags/v1.0', head_commit = {id = '0123', message = 'release'}}),
        204, 'tag accepted')
    T.eq(plain_all(c:take()), {
        'NOTICE #rutile :[Libera-Chat/rutile] glguy pushed tag v1.0 012345678: release - https://example.test/compare',
    }, 'tag announced')
    T.eq(deliver(listener, 'push', push {ref = 'refs/heads/new'}), 204, 'new branch accepted')
    T.eq(plain_all(c:take()), {
        'NOTICE #rutile :[Libera-Chat/rutile] glguy pushed new 012345678: head - https://example.test/compare',
    }, 'new branch announced')
end)

T.case('null fields count as absent', function()
    local c, listener = boot()
    c:take()
    T.eq(deliver(listener, 'push', push {ref = 'refs/heads/gone', head_commit = json_null}), 204, 'deleted branch')
    T.eq(c:take(), {}, 'nothing announced for a deleted branch')
    T.eq(deliver(listener, 'pull_request_review', payload {
        action = 'submitted',
        pull_request = {number = 7, title = 'Fix'},
        review = {state = 'approved', body = json_null, html_url = 'https://example.test/r'},
    }), 204, 'review')
    T.eq(plain_all(c:take()), {
        'NOTICE #rutile :[Libera-Chat/rutile] glguy approved PR #7 (Fix) - https://example.test/r',
    }, 'a review without text')
end)

T.case('payloads without a repository or organization are ignored', function()
    local c, listener = boot()
    c:take()
    T.eq(deliver(listener, 'sponsorship', to_json {action = 'created', sender = {login = 'x'}}), 204, 'accepted')
    T.eq(c:take(), {}, 'nothing announced')
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

T.case('long text is cut on a character boundary', function()
    local c, listener = boot()
    c:take()
    -- 'é' is two bytes; the 99th byte falls inside one
    local title = string.rep('a', 98) .. string.rep('é', 10)
    T.eq(deliver(listener, 'issues', payload {
        action = 'opened',
        issue = {number = 3, title = title, html_url = 'https://example.test/i'},
    }), 204, 'accepted')
    local line = c:take()[1]
    T.ok(utf8.len(line), 'valid UTF-8: ' .. line)
    T.ok(plain(line):find(string.rep('a', 98) .. '…', 1, true), 'cut before the split character')
end)

T.case('mutes', function()
    local c, listener = boot()
    c:take()
    T.eq(staff(c, 'mute project=' .. REPO .. ' pr=12a'), {'NOTICE staffer :Bad pr: 12a'}, 'bad pr refused')
    T.eq(staff(c, 'mute issue=x'), {'NOTICE staffer :Bad issue: x'}, 'bad issue refused')
    T.eq(staff(c, 'mute bogus'), {'NOTICE staffer :Syntax error near: bogus'}, 'syntax error')
    T.eq(staff(c, 'mute'), {'NOTICE staffer :No criteria specified'}, 'no criteria')
    T.eq(saved().mutes, {}, 'none of those saved')

    T.eq(staff(c, 'mute pr=12 days=1 hours=2'), {'NOTICE staffer :Added mute 1'}, 'mute a PR')
    local mute = saved().mutes[1]
    T.eq(mute.rule, {pr = 12}, 'rule')
    T.ok(math.abs(mute.expire - os.time() - 26 * 3600) < 5, 'days and hours add up')

    -- a comment on the PR's conversation is an issue_comment
    T.eq(deliver(listener, 'issue_comment', payload {
        action = 'created',
        issue = {number = 12, title = 'PR', pull_request = {url = 'x'}},
        comment = {body = 'hi', html_url = 'https://example.test/c'},
    }), 204, 'comment')
    T.eq(c:take(), {}, 'muted')
    T.eq(deliver(listener, 'pull_request', payload {
        action = 'opened',
        pull_request = {number = 13, title = 'Other', html_url = 'https://example.test/p'},
    }), 204, 'another PR')
    T.eq(#c:take(), 1, 'not muted')

    T.eq(staff(c, 'mutes')[1]:match '^NOTICE staffer :1: expire=1d2h', 'NOTICE staffer :1: expire=1d2h', 'listed')
    T.eq(staff(c, 'unmute 1'), {'NOTICE staffer :Removed mute'}, 'unmuted')
    T.eq(staff(c, 'mutes'), {'NOTICE staffer :No mutes'}, 'none left')
end)

T.case('expired mutes are dropped', function()
    local c, listener = boot()
    c:take()
    T.eq(staff(c, 'mute sender=glguy hours=0.0001'), {'NOTICE staffer :Added mute 1'}, 'a short mute')
    T.sleep(1100)
    c:take() -- hub's own traffic while waiting, such as a lag check
    T.eq(deliver(listener, 'push', push()), 204, 'accepted')
    T.eq(#c:take(), 1, 'announced')
    T.eq(saved().mutes, {}, 'expired mute removed')
end)

T.case('staff commands in private message', function()
    local c = boot()
    c:take()
    T.eq(staff(c, 'projects'), {'NOTICE staffer :Projects: ' .. REPO}, 'projects')
    c:recv ':someone!u@host.example PRIVMSG me :projects'
    T.eq(c:take(), {}, 'only staff')
    T.eq(staff(c, 'projects', '#rutile'), {}, 'only private messages')
    T.eq(staff(c, 'event_on ' .. REPO .. ' nope:nope'), {'NOTICE staffer :Unknown event'}, 'unknown event')
    T.eq(staff(c, 'event_on ' .. REPO .. ' star:created'), {'NOTICE staffer :Event not yet implemented'},
        'event without a formatter')
    T.eq(staff(c, 'event_on ' .. REPO .. ' issues:closed'), {'NOTICE staffer :Event enabled'}, 'event on')
    T.ok(saved().projects[REPO].events['issues:closed'], 'saved')
    T.eq(staff(c, 'set_push_limit ' .. REPO .. ' 5'), {'NOTICE staffer :Push limit for ' .. REPO .. ' is now 5'},
        'push limit')
    T.eq(staff(c, 'set_push_limit ' .. REPO .. ' 50'), {'NOTICE staffer :limit argument out of bounds'}, 'bounds')
    T.ok(staff(c, 'help')[1]:find('Commands:', 1, true), 'help')
end)

T.case('client commands save, join and check events', function()
    local c = boot()
    c:take()
    -- registered in the order the plugin lists them, which /help keeps
    local names = {}
    for name, cmd in pairs(HUB.current.commands) do
        if cmd.group == 'plugin github' then table.insert(names, {cmd.order, name}) end
    end
    table.sort(names, function(x, y) return x[1] < y[1] end)
    for i, entry in ipairs(names) do names[i] = entry[2] end
    T.eq(names, {'gh_replay', 'gh_debug_on', 'gh_debug_off', 'gh_set_credential', 'gh_drop_credential',
        'gh_authorize', 'gh_deauthorize', 'gh_add_project', 'gh_set_channel', 'gh_drop_project',
        'gh_event_on', 'gh_event_off', 'gh_event_copy_from_to', 'gh_set_port'}, 'in order')
    T.eq(HUB.current.commands.gh_authorize.usage, 'repo authid', 'with usages')

    command 'gh_add_project a/b #new'
    T.eq(T.log_lines 'error', {}, 'added')
    T.ok(table.concat(c:take(), ' '):find('#new', 1, true), 'joined the new channel')
    T.eq(saved().projects['a/b'].channel, '#new', 'saved')

    local strict = HUB.boot.strict
    HUB.boot.strict = false
    command 'gh_event_on a/b pull_request:open'
    HUB.boot.strict = strict
    T.ok(T.log_lines('error')[1]:find('Unknown event', 1, true), 'misspelled event refused')
    T.eq(saved().projects['a/b'].events, {}, 'not saved')

    command 'gh_event_on a/b pull_request:opened'
    T.ok(saved().projects['a/b'].events['pull_request:opened'], 'event on')
    command 'gh_drop_credential gh'
    T.eq(saved().credentials.gh, nil, 'credential dropped')
    T.eq(saved().projects[REPO].authorized, {}, 'and its authorizations')
end)

T.case('saved data survives a restart', function()
    local c = boot()
    c:take()
    staff(c, 'set_push_limit ' .. REPO .. ' 3')
    local real = snowcone.start_httpd
    snowcone.start_httpd = function() return {close = function() end} end
    T.boot {config = {
        plugins = {directory = dir, modules = {'github'}, custom = {github = {network = 'libera'}}},
        networks = {},
    }}
    snowcone.start_httpd = real
    T.eq(saved().projects[REPO].push_limit, 3, 'kept')
end)

T.case('the view draws', function()
    boot()
    local control = T.require 'hub.ui.control'
    control.set_view 'github'
    HUB.current.routes['ui.draw']()
    T.eq(T.log_lines 'error', {}, 'no errors')
end)

-- a case of its own: T.run returns at the first sleep, before later cases
T.case('remove the plugin directory', function()
    for _, name in ipairs {'github.lua', 'github.events.txt', 'github.dat'} do
        os.remove(path.join(dir, name))
    end
    T.ok(os.remove(dir), 'removed')
end)

T.run()
