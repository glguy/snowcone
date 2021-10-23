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
        elseif kind == 'iden' and colormap[token] then
            watch.color = colormap[token]
        elseif kind == 'string' then
            watch.mask = token
        elseif kind == 'number' and math.tointeger(token) then
            id = math.tointeger(token)
            if id < 1 or #watches < id then
                status_message = "Watch index out of range"
                return
            end
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

        table.insert(watches, watch)
        status_message = "Added watch #" .. #watches

    -- Updating an old watch
    else
        tablex.update(watches[id], watch)
        status_message = "Updated watch #" .. id
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

return M
