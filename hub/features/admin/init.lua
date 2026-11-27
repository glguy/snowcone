-- Server administration: the commands for running the servers, which
-- most opers have no privileges for, with the arguments as Solanum's
-- handlers read them:
--
--   /modlist [pattern] [server]   the modules loaded, shown as a table
--   /modload [path/]module [server]                  (modules/core/m_modules.c)
--   /modunload module [server]
--   /modreload module [server]
--   /modrestart [server]          unload every module, then load autoload's
--   /serverconnect server [port] [from]   CONNECT     (modules/m_connect.c)
--   /serverquit server [reason]           SQUIT       (modules/core/m_squit.c)
--   /serverrehash [option] [server]       REHASH      (modules/m_rehash.c)
--   /serverdie server                     DIE         (modules/core/m_die.c)
--   /serverrestart server                 RESTART     (modules/m_restart.c)
--   /grant nick privset|deoper            GRANT       (modules/m_grant.c)
--   /dehelper nick                        DEHELPER    (extensions/helpops.c)
--   /shedding server rate reason          SHEDDING    (extensions/m_shedding.c)
--   /shedding server OFF
--
-- A module command's server may be a mask, sent on to each server it
-- matches, but for MODLIST: its listing takes the first end, so it asks
-- one server, named without wildcards. As REHASH's: a lone word is a
-- server when it has a dot or a wildcard, else an option. DIE and
-- RESTART name the server to stop, which must be its name in full: the
-- server checks it, as the confirmation. SHEDDING's server is a name
-- without wildcards, and its rate seconds between users shed, at least 5. These but MODLIST have no
-- numeric reply: the server says what it did in a notice, and in server
-- notices to opers with +s.
--
-- OFTC hybrid has CONNECT, SQUIT, DIE and RESTART alike, but only of our
-- server for the last two, and REHASH of its own options and only ours. It
-- manages modules with its MODULE command, which these don't cover, and
-- has no GRANT, DEHELPER or SHEDDING.

local common  <const> = require 'hub.features.common'
local ircd    <const> = require 'hub.net.ircd'
local listing <const> = require 'hub.features.queries.listing'
local send    <const> = require 'hub.net.send'
local task    <const> = require 'hub.runtime.task'

local M = {}

M.name = 'admin'

local admin_command <const> = common.net_command(M.name)

-- A command Solanum has and hybrid doesn't, refused on hybrid with a hint
local function solanum_command(hint)
    return function(name, spec, usage, help, fn)
        return admin_command(name, spec, usage, help, function(ctx, ...)
            if ircd.hybrid(ctx.net) then error('OFTC hybrid has no ' .. name:upper() .. hint, 0) end
            return fn(ctx, ...)
        end)
    end
end

local module_command <const> = solanum_command '; use /quote MODULE'
local extension_command <const> = solanum_command ''

-- SHEDDING's least rate, in seconds (extensions/m_shedding.c)
local shed_rate_min <const> = 5

local function words_of(rest)
    local words = {}
    for w in rest:gmatch '%S+' do table.insert(words, w) end
    return words
end

-- REHASH's options, as each server has them
local rehash_options <const> = {
    'BANS', 'DNS', 'HELP', 'MOTD', 'NICKDELAY', 'OMOTD', 'REJECTCACHE', 'SSLD', 'TDLINES', 'THROTTLES',
    'TKLINES', 'TRESVS', 'TXLINES',
}
local rehash_options_hybrid <const> = {'DNS', 'FDLIMIT', 'MOTD', 'OMOTD'}

local function options_of(net)
    return ircd.hybrid(net) and rehash_options_hybrid or rehash_options
end

local function is_option(net, word)
    for _, option in ipairs(options_of(net)) do
        if option == word:upper() then return true end
    end
    return false
end

local function rehash_command()
    local cmd = admin_command('serverrehash', '$R', '[option] [server]',
        'REHASH the config, or what an option names (BANS, MOTD, TKLINES ...), on a server or a mask of them',
    function(ctx, rest)
        local words = words_of(rest)
        if #words > 2 then error('an option and a server: ' .. rest, 0) end
        local option, server = words[1], words[2]
        -- as the server reads one word
        if option and not server and option:find '[.*?]' then option, server = nil, option end
        if option and not is_option(ctx.net, option) then
            error(string.format('not a REHASH option: %s (%s)', option, table.concat(options_of(ctx.net), ', ')), 0)
        end
        if server and ircd.hybrid(ctx.net) then error('OFTC hybrid rehashes only our server', 0) end
        local args = {}
        if option then table.insert(args, option:upper()) end
        if server then table.insert(args, server) end
        send.send(ctx.net, 'REHASH', table.unpack(args))
    end)
    function cmd.complete(ctx, before, seed)
        if before:find '%S' then return nil end
        local t = {}
        for _, option in ipairs(options_of(ctx.net)) do
            if option:sub(1, #seed) == seed:upper() then table.insert(t, option) end
        end
        return t
    end
    return cmd
end

-- DIE or RESTART a server, named in full; Solanum takes a remote one as
-- the name to check and the server to send it to, which works for ours
-- too
local function stop_command(name, command, help)
    return admin_command(name, '$a', 'server', help, function(ctx, server)
        if server:find '[*?]' then error(command .. ' names one server in full: ' .. server, 0) end
        if ircd.hybrid(ctx.net) then
            send.send(ctx.net, command, server)
        else
            send.send(ctx.net, command, server, server)
        end
    end)
end

-- The one word of an optional rest, or nil when empty
local function one_word(what, rest)
    if rest:find ' ' then error('one ' .. what .. ': ' .. rest, 0) end
    if rest ~= '' then return rest end
end

-- A command taking a module and maybe a server
local function on_module(name, usage, help)
    local command = name:upper()
    return module_command(name, '$a $R', usage, help, function(ctx, module, server)
        local where = one_word('server', server)
        if where then
            send.send(ctx.net, command, module, where)
        else
            send.send(ctx.net, command, module)
        end
    end)
end

M.commands = {
    module_command('modlist', '$R', '[pattern] [server]',
        'MODLIST the modules loaded, whose names match a pattern, of a server or ours, shown as a table',
    function(ctx, rest)
        local pattern, server, extra = rest:match '^(%S+) (%S+) ?(.*)$'
        if not pattern then pattern = one_word('pattern', rest) end
        if extra and extra ~= '' then error('a pattern and a server: ' .. rest, 0) end
        if server and server:find '[*?]' then error('MODLIST asks one server, named in full: ' .. server, 0) end
        task.spawn('modlist', {net = ctx.net, owner = M.name}, listing.modlist, pattern, server)
    end),
    on_module('modload', '[path/]module [server]', 'MODLOAD a module, on a server or a mask of them'),
    on_module('modunload', 'module [server]', 'MODUNLOAD a module, on a server or a mask of them'),
    on_module('modreload', 'module [server]', 'MODRELOAD a module, on a server or a mask of them'),
    module_command('modrestart', '$R', '[server]',
        'MODRESTART: unload every module and load those of autoload, on a server or a mask of them',
    function(ctx, server)
        local where = one_word('server', server)
        if where then
            send.send(ctx.net, 'MODRESTART', where)
        else
            send.send(ctx.net, 'MODRESTART')
        end
    end),
    admin_command('serverconnect', '$a $R', 'server [port] [from]',
        'CONNECT a server to ours, or to the server from; port 0 or none is its connect block\'s',
    function(ctx, server, rest)
        local words = words_of(rest)
        if #words > 2 then error('a port and a server: ' .. rest, 0) end
        local port, from = words[1], words[2]
        if port and not math.tointeger(tonumber(port)) then
            -- the server to connect from, with the connect block's port
            if from then error('the port comes before the server: ' .. rest, 0) end
            port, from = '0', port
        end
        if port and (tonumber(port) < 0 or tonumber(port) > 65535) then error('not a port: ' .. port, 0) end
        local args = {server}
        if port then table.insert(args, port) end
        if from then table.insert(args, from) end
        send.send(ctx.net, 'CONNECT', table.unpack(args))
    end),
    admin_command('serverquit', '$a $T', 'server [reason]', 'SQUIT a server off the network, with a reason',
    function(ctx, server, reason)
        if reason ~= '' then
            send.send(ctx.net, 'SQUIT', server, reason)
        else
            send.send(ctx.net, 'SQUIT', server)
        end
    end),
    rehash_command(),
    stop_command('serverdie', 'DIE', 'DIE: shut a server down, named in full'),
    stop_command('serverrestart', 'RESTART', 'RESTART a server, named in full'),
    extension_command('grant', '$a $a', 'nick privset|deoper',
        "GRANT: oper a nick with a privilege set, change its set, or deoper it",
    function(ctx, nick, privset)
        send.send(ctx.net, 'GRANT', nick, privset)
    end),
    extension_command('dehelper', '$a', 'nick', 'DEHELPER: take helper status (+h) from a nick', function(ctx, nick)
        send.send(ctx.net, 'DEHELPER', nick)
    end),
    extension_command('shedding', '$a $a $T', 'server rate|OFF [reason]',
        'SHEDDING: disconnect a user from a server every rate seconds, for a reason, until OFF',
    function(ctx, server, rate, reason)
        if server:find '[*?]' then error('SHEDDING names one server in full: ' .. server, 0) end
        if rate:upper() == 'OFF' then
            if reason ~= '' then error('OFF takes no reason', 0) end
            return send.send(ctx.net, 'SHEDDING', server, 'OFF')
        end
        local seconds = math.tointeger(tonumber(rate))
        if not seconds or seconds < shed_rate_min then
            error(string.format('a rate is %d seconds or more, or OFF: %s', shed_rate_min, rate), 0)
        end
        if reason == '' then error('shedding takes a reason', 0) end
        send.send(ctx.net, 'SHEDDING', server, rate, reason)
    end),
}

return M
