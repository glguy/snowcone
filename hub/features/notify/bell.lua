-- Notification by terminal bell.

local M = {}

function M.notify(previous)
    if not previous then
        io.stdout:write '\x07'
        io.stdout:flush()
    end
    return true
end

function M.dismiss() end

return M
