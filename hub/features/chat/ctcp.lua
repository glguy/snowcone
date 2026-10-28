-- Replies to CTCP requests. The chat feature answers only requests sent
-- to us by network staff.

local M = {}

function M.CLIENTINFO()
    local names = {}
    for k in pairs(M) do table.insert(names, k) end
    table.sort(names)
    return table.concat(names, ' ')
end

function M.PING(args)
    return args
end

function M.SOURCE()
    return 'https://github.com/glguy/snowcone'
end

function M.TIME()
    return os.date '!%c'
end

-- A fixed string: a reply shouldn't start a process (such as git) to
-- find a version
function M.VERSION()
    return 'snowcone hub'
end

return M
