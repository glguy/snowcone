-- Running a command typed on the command line.

local control <const> = require 'hub.ui.control'
local log     <const> = require 'hub.runtime.log'

local M = {}

--- Error handler: a traceback for errors from code (those with a source
--- position), just the message for errors raised for the user with level 0.
function M.traceback(err)
    if type(err) == 'string' and not err:match '^[^:\n]+:%d+:' then
        return err
    end
    return debug.traceback(err, 2)
end

--- Parse and run one command line (without the leading slash).
---@param text string
function M.execute(text)
    local name, args = text:match '^ *(%g*) *(.*)$'
    local cmd = HUB.current.commands[name]
    if cmd == nil then
        log.add('error', 'unknown command: %s', name)
        return
    end

    -- a net command may name its network first: /quote @libera ...
    local net = control.current_net()
    if cmd.scope == 'net' then
        local at, rest = args:match '^@(%S+)%s*(.*)$'
        if at then
            if not HUB.state.nets[at] then
                log.add('error', 'no such network: %s', at)
                return
            end
            net, args = at, rest
        end
        if net == nil then
            log.add('error', '%s needs a network', name)
            return
        end
    end

    local params = {}
    if not cmd.pattern(args, params) then
        log.add('error', '%s requires: %s', name, cmd.spec)
        return
    end

    log.dismiss()
    local ctx = {net = net}
    local ok, err = xpcall(cmd.fn, M.traceback, ctx, table.unpack(params))
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
