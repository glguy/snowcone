local tablex = require 'pl.tablex'

local M = {}

function M.CLIENTINFO(args)
    local commands = tablex.keys(M)
    table.sort(commands)
    return table.concat(commands, ' ')
end

function M.PING(args)
    return args
end

function M.SOURCE(args)
    return 'https://github.com/glguy/snowcone'
end

function M.TIME(args)
    return os.date('!%c')
end

function M.VERSION()
    local f = io.popen('git rev-parse HEAD')
    local hash = f:read() or '*'
    f:close()
    return 'snowcone ' .. hash
end

return M
