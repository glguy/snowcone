local tablex = require 'pl.tablex'
local lexer = require 'pl.lexer'
local sip = require 'pl.sip'

local colormap =
  { black = ncurses.black, red = ncurses.red, green = ncurses.green,
    yellow = ncurses.yellow, blue = ncurses.blue, magenta = ncurses.magenta,
    cyan = ncurses.cyan, white = ncurses.white, }

local M = {}

--[[
Type      Meaning
v         identifier
i         possibly signed integer
f         floating-point number
r         rest of line
q         quoted string (quoted using either ' or ")
p         a path name
(         anything inside balanced parentheses
[         anything inside balanced brackets
{         anything inside balanced curly brackets
<         anything inside balanced angle brackets

g         any non-empty printable sequence
R         rest of line (allowing empty)
]]

sip.custom_pattern('g', '(%g+)')
sip.custom_pattern('R', '(.*)')

local function add_command(name, spec, func)
    local pattern
    if spec == '' then
        pattern = function(args) return args == '' end
    else
        pattern = assert(sip.compile(spec, {at_start=true}))
    end

    M[name] = {
        spec = spec,
        pattern = pattern,
        func = func,
    }
end

add_command('quote', '$r', function(args)
    snowcone.send_irc(args .. '\r\n')
end)

add_command('nettrack', '$g $g', function(name, mask)
    add_network_tracker(name, mask)
end)

add_command('filter', '$R', function(args)
    if args == '' then
        filter = nil
    else
        filter = args
    end
end)

add_command('sync', '', function()
    snowcone.send_irc(counter_sync_commands())
end)

add_command('reload', '', function()
    assert(loadfile(configuration.lua_filename))()
end)

add_command('eval', '$r', function(args)
    local chunk, message = load(args, '=(eval)', 't')
    if chunk then
        local _, ret = pcall(chunk)
        if ret then
            status_message = tostring(ret)
        else
            status_message = nil
        end
    else
        status_message = message
    end
end)

add_command('quit', '', quit)

add_command('inject', '$r', function(arg)
    local parse_snote = require 'utils.parse_snote'
    local time = os.date('!%H:%M:%S')
    local server = 'INJECT.'
    local event = parse_snote(time, server, arg)
    if event then
        local handlers = require 'handlers.snotice'
        local handler = handlers[event.name]
        if handler then
            handler(event)
        else
            status_message = 'no handler'
        end
    else
        status_message = 'parse failed'
    end
end)

add_command('addwatch', '$r', function(args)
    local watch = {}
    local id
    for kind, token in lexer.scan(args) do

        if kind == 'iden' and token == 'beep' then
            watch.beep = true

        elseif kind == 'iden' and token == 'flash' then
            watch.flash = true

        elseif kind == 'iden' and token == 'nobeep' then
            watch.beep = false

        elseif kind == 'iden' and token == 'noflash' then
            watch.flash = false

        elseif kind == 'iden' and colormap[token] then
            watch.color = colormap[token]

        elseif kind == 'iden' and token == 'filter' then
            watch.mask = filter

        elseif kind == 'string' then
            watch.mask = token

        elseif kind == 'number' and math.tointeger(token) then
            id = math.tointeger(token)

        else
            status_message = "Unexpected token: " .. token
            return
        end
    end

    -- New watch
    if id == nil then
        if watch.mask == nil then
            status_message = "No watch mask specified"
            return
        end

        watch.active = true
        watch.hits = 0

        table.insert(watches, watch)
        status_message = "Added watch #" .. #watches

    -- Updating an old watch
    else
        local previous = watches[id]
        if previous then
            tablex.update(previous, watch)
            status_message = "Updated watch #" .. id
        else
            status_message = "So such watch"
        end
    end
end)

add_command('delwatch', '$i', function(i)
    if watches[i] then
        table.remove(watches, i)
    elseif i == nil then
        status_message = 'delwatch requires integer argument'
    else
        status_message = 'delwatch index out of range'
    end
end)

add_command('stats', '', function()
    view = 'stats'
end)

add_command('repeats', '', function()
    view = 'repeats'
end)

add_command('banload', '', function()
    view = 'banload'
end)

add_command('spamload', '', function()
    view = 'spamload'
end)

add_command('channels', '', function()
    view = 'channels'
end)

add_command('versions', '', function()
    local n = 0
    local commands = {}
    for server, _ in pairs(links) do
        n = n + 1
        commands[n] = 'VERSION :' .. server .. '\r\n'
    end
    versions = {}
    snowcone.send_irc(table.concat(commands))
end)

add_command('uptimes', '', function()
    local n = 0
    local commands = {}
    for server, _ in pairs(links) do
        n = n + 1
        commands[n] = 'STATS u :' .. server .. '\r\n'
    end
    uptimes = {}
    snowcone.send_irc(table.concat(commands))
end)

-- Pretending to be an IRC client

add_command('msg', '$g $r', function(target, message)
    snowcone.send_irc('PRIVMSG ' .. target .. ' :' .. message .. '\r\n')
end)

add_command('notice', '$g $r', function(target, message)
    snowcone.send_irc('NOTICE ' .. target .. ' :' .. message .. '\r\n')
end)

return M
