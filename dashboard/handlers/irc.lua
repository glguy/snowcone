-- Logic for IRC messages
local Set         = require 'pl.Set'
local Task        = require 'components.Task'
local N           = require_ 'utils.numerics'
local challenge   = require_ 'utils.challenge'
local parse_snote = require_ 'utils.parse_snote'
local send        = require 'utils.send'
local split_nuh   = require_ 'utils.split_nick_user_host'
local configuration_tools = require_ 'utils.configuration_tools'

local function parse_source(source)
    return string.match(source, '^(.-)!(.-)@(.*)$')
end

local M = {}

function M.ERROR()
    irc_state.phase = 'closed'
end

function M.PING(irc)
    send('PONG', irc[1])
end

local cap_cmds = require_ 'handlers.cap'
function M.CAP(irc)
    -- irc[1] is a nickname or *
    local h = cap_cmds[irc[2]]
    if h then
        h(table.unpack(irc, 3))
    end
end

-- "<client> :Welcome to the <networkname> Network, <nick>[!<user>@<host>]"
M[N.RPL_WELCOME] = function(irc)
    irc_state.nick = irc[1]
end

-- "<client> <1-13 tokens> :are supported by this server"
M[N.RPL_ISUPPORT] = function(irc)
    for i = 2, #irc - 1 do
        local token = irc[i]
        -- soju.im/bouncer-networks happens to add _ to the allowed characters
        local minus, key, equals, val = token:match '^(%-?)([%u%d_]+)(=?)(.*)$'
        if minus == '-' then
            val = nil
        elseif equals == '' then
            val = true
        end
        irc_state:set_isupport(key, val)
    end
end

local function end_of_registration()
    irc_state.phase = 'connected'
    status('irc', 'registered')

    if configuration.challenge and configuration.challenge.automatic
    and configuration.challenge.username and configuration.challenge.key then
        Task(irc_state.tasks, challenge)
    elseif configuration.oper and configuration.oper.automatic
    and configuration.oper.username and configuration.oper.password then
        Task(irc_state.tasks, function(task)
            local oper_password =
                configuration_tools.resolve_password(task, configuration.oper.password)
            send('OPER', configuration.oper.username, {content=oper_password, secret=true})
        end)
    else
        -- assume we get oper from a proxy
        counter_sync_commands()
    end
end

-- "<client> :End of /MOTD command."
M[N.RPL_ENDOFMOTD] = function()
    if irc_state.phase == 'registration' then
        end_of_registration()
    end
end

-- "<client> :MOTD File is missing"
M[N.ERR_NOMOTD] = function()
    if irc_state.phase == 'registration' then
        end_of_registration()
    end
end

M[N.RPL_SNOMASK] = function(irc)
    status('irc', 'snomask %s', irc[2])
end

M[N.RPL_YOUREOPER] = function()
    irc_state.oper = true
    counter_sync_commands()
    send('MODE', irc_state.nick, 's', 'BFZbcklnsx')
    status('irc', "you're oper")
end

local function new_nickname()
    if irc_state.phase == 'registration' then
        local nick = string.format('%.10s-%05d', configuration.identity.nick, math.random(0,99999))
        irc_state.nick = nick
        irc_state.target_nick = configuration.identity.nick
        send('NICK', nick)
    end
end

M[N.ERR_ERRONEUSNICKNAME] = new_nickname
M[N.ERR_NICKNAMEINUSE] = new_nickname
M[N.ERR_UNAVAILRESOURCE] = new_nickname

-----------------------------------------------------------------------

M[N.RPL_TESTMASKGECOS] = function(irc)
    local loc, rem, mask, gecos = table.unpack(irc,2,5)
    local total = math.tointeger(loc) + math.tointeger(rem)

    -- If the current staged_action is for this particular mask update the count
    if staged_action and staged_action.mask
    and '*' == gecos
    and '*!'..staged_action.mask == mask then
        staged_action.count = total
    end
    if gecos == '*' and mask:startswith '*!*@' then
        local label = string.sub(mask, 5)
        for _, entry in pairs(net_trackers) do
            entry:set(label, total)
        end
    end
end

M[N.RPL_MAP] = function(irc)
    if not irc_state.in_map then
        population = {}
        irc_state.in_map = true
    end

    local server, count = string.match(irc[2], '(%g*)%[...%] %-* | Users: +(%d+)')
    if server then
        population[server] = math.tointeger(count)
    end
end

M[N.RPL_MAPEND] = function()
    irc_state.in_map = nil
end

M[N.RPL_VERSION] = function(irc)
    versions[irc.source] = string.match(irc[2] or '', '%((.*)%)')
end

M[N.RPL_LINKS] = function(irc)
    if not irc_state.links then
        irc_state.links = {}
    end

    local server, linked = table.unpack(irc, 2, 3)
    irc_state.links[server] = Set{linked}
    if irc_state.links[linked] then
        irc_state.links[linked][server] = true
    end
end

M[N.RPL_ENDOFLINKS] = function()
    links = irc_state.links
    irc_state.links = nil

    local primary_hub = servers.primary_hub
    if primary_hub then
        upstream = {[primary_hub] = primary_hub}
        local q = {primary_hub}
        for _, here in ipairs(q) do
            for k, _ in pairs(links[here] or {}) do
                if not upstream[k] then
                    upstream[k] = here
                    table.insert(q, k)
                end
            end
        end
    end
end

M[N.RPL_STATSUPTIME] = function(irc)
    local days, h, m, s = string.match(irc[2], ' (%d+) days, (%d+):(%d+):(%d+)$')
    local now = os.time()
    local startup = now - 86400 * days - 3600 * h - 60 * m - s
    local text = os.date('!%Y-%m-%d %H:%M:%S', startup)
    uptimes[irc.source] = text
end

-- <client> <mechanisms> :are available SASL mechanisms
M[N.RPL_SASLMECHS] = function(irc)
    irc_state:set_sasl_mechs(irc[2])
end

local ctcp_handlers = require_ 'handlers.ctcp'
function M.PRIVMSG(irc)
    local target, message = irc[1], irc[2]
    local ctcp, ctcp_args = message:match '^\x01(%S+) ?([^\x01]*)\x01?$'
    if ctcp and not target:startswith '#' and irc.tags['solanum.chat/oper'] then
        ctcp = ctcp:upper()
        local nick = split_nuh(irc.source)
        local h = ctcp_handlers[ctcp]
        if h then
            local response = h(ctcp_args)
            if response then
                send('NOTICE', nick, '\x01' .. ctcp .. ' ' .. response .. '\x01')
            end
        end
    end
end

local handlers = require_ 'handlers.snotice'
function M.NOTICE(irc)
    if irc[1] == '*' and not string.match(irc.source, '@') then
        local note = string.match(irc[2], '^%*%*%* Notice %-%- (.*)$')
        if note then
            local event = parse_snote(irc.time, irc.source, note)
            if event then
                local handled = false

                local h = handlers[event.name]
                if h then
                    h(event)
                    handled = true
                end

                for _, plugin in pairs(plugins) do
                    h = plugin.snotice
                    if h then
                        local success, err = pcall(h, event)
                        if not success then
                            status(plugin.name, 'snotice handler error: ' .. tostring(err))
                        end
                        handled = true
                    end
                end

                if handled and views[view].active then
                    draw()
                end
            end
        end
    end
end

M.NICK = function(irc)
    local nick = parse_source(irc.source)
    if nick and nick == irc_state.nick then
        irc_state.nick = irc[1]
        if irc_state.target_nick == irc_state.nick then
            irc_state.target_nick = nil
        end
    end
end

return M
