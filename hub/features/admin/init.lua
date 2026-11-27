-- Server administration: the commands an oper needs oper:admin for,
-- which most opers have no use for. For now Solanum's modules, with the
-- arguments as its handlers read them (modules/core/m_modules.c):
--
--   /modlist [pattern] [server]   the modules loaded, shown as a table
--   /modload [path/]module [server]
--   /modunload module [server]
--   /modreload module [server]
--   /modrestart [server]          unload every module, then load autoload's
--
-- A server may be a mask, sent on to each server it matches, but for
-- MODLIST: its listing takes the first end, so it asks one server, named
-- without wildcards. The others have no numeric reply: the server says
-- what it did in a notice, and in server notices to opers with +s.
--
-- OFTC hybrid manages modules with its MODULE command, which these don't
-- cover.

local common  <const> = require 'hub.features.common'
local ircd    <const> = require 'hub.net.ircd'
local listing <const> = require 'hub.features.queries.listing'
local send    <const> = require 'hub.net.send'
local task    <const> = require 'hub.runtime.task'

local M = {}

M.name = 'admin'

local admin_command <const> = common.net_command(M.name)

-- A module command, refused on hybrid
local function module_command(name, spec, usage, help, fn)
    return admin_command(name, spec, usage, help, function(ctx, ...)
        if ircd.hybrid(ctx.net) then error('OFTC hybrid has no ' .. name:upper() .. '; use /quote MODULE', 0) end
        return fn(ctx, ...)
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
}

return M
