local tablex = require 'pl.tablex'
local lexer = require 'pl.lexer'

local colormap =
  { black = ncurses.black, red = ncurses.red, green = ncurses.green,
    yellow = ncurses.yellow, blue = ncurses.blue, magenta = ncurses.magenta,
    cyan = ncurses.cyan, white = ncurses.white, }

local M = {}

function M.quote(args)
    snowcone.send_irc(args .. '\r\n')
end

function M.nettrack(args)
    local name, mask = string.match(args, '(%g+) +(%g+)')
    if name then
        add_network_tracker(name, mask)
    end
end

function M.filter(args)
    if args == '' then
        filter = nil
    else
        filter = args
    end
end

function M.sync()
    snowcone.send_irc(counter_sync_commands())
end

function M.reload()
    assert(loadfile(configuration.lua_filename))()
end

function M.eval(args)
    local chunk, message = load(args, '=(eval)', 't')
    if chunk then
        local _, ret = pcall(chunk)
        if ret then
            status_message = string.match(tostring(ret), '^%C*')
        else
            status_message = nil
        end
    else
        status_message = string.match(message, '^%C*')
    end
end

function M.quit()
    quit()
end

function M.inject(arg)
    local parse_snote = require 'parse_snote'
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
end

function M.addwatch(args)
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
end

function M.delwatch(args)
    local i = math.tointeger(args)
    if watches[i] then
        table.remove(watches, i)
    elseif i == nil then
        status_message = 'delwatch requires integer argument'
    else
        status_message = 'delwatch index out of range'
    end
end

function M.stats()
    view = 'stats'
end

function M.repeats()
    view = 'repeats'
end

function M.banload()
    view = 'banload'
end

function M.spamload()
    view = 'spamload'
end

function M.versions()
    local n = 0
    local commands = {}
    for server, _ in pairs(links) do
        n = n + 1
        commands[n] = 'VERSION :' .. server .. '\r\n'
    end
    versions = {}
    snowcone.send_irc(table.concat(commands))
end

return M
