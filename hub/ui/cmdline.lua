-- Running a command typed on the command line.

local log <const> = require 'hub.runtime.log'

local M = {}

--- Parse and run one command line (without the leading slash).
---@param text string
function M.execute(text)
    local name, args = text:match '^ *(%g*) *(.-) *$'
    local cmd = HUB.current.commands[name]
    if cmd == nil then
        log.add('error', 'unknown command: %s', name)
        return
    end

    local params = {}
    if not cmd.pattern(args, params) then
        log.add('error', '%s requires: %s', name, cmd.spec)
        return
    end

    log.dismiss()
    local ctx = {net = HUB.state.ui.current_net}
    local ok, err = xpcall(cmd.fn, debug.traceback, ctx, table.unpack(params))
    if not ok then
        log.error(name, err)
    end
end

--- Command names starting with a prefix, sorted.
---@param seed string
---@return string[]
function M.complete(seed)
    local t = {}
    for k in pairs(HUB.current.commands) do
        if k:sub(1, #seed) == seed then
            table.insert(t, k)
        end
    end
    table.sort(t)
    return t
end

return M
