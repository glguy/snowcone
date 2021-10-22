
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

return M
