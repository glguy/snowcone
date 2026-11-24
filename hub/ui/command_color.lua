-- The color a command is drawn in: command_color(net, command).

local draw <const> = require 'hub.ui.draw'
local ircd <const> = require 'hub.net.ircd'

-- Colors of commands; errors are red.
local palette <const> = {
    PRIVMSG = draw.blue,
    NOTICE = draw.cyan,
    JOIN = draw.green,
    PART = draw.yellow,
    QUIT = draw.magenta,
}

--- The color of a command on a network, or nil.
---@param net string|nil
---@param command string|integer
return function(net, command)
    local name = ircd.numeric_name(net, command)
    if name and name:sub(1, 4) == 'ERR_' then return draw.red end
    return palette[command]
end
