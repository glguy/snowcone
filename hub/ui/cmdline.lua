-- Running a command typed on the command line.

local common    <const> = require 'hub.features.common'
local control   <const> = require 'hub.ui.control'
local log       <const> = require 'hub.runtime.log'
local traceback <const> = require 'hub.lib.traceback'

local M = {}

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
        if cmd.feature and not common.enabled(net, cmd.feature) then
            log.add('error', '%s needs the %s feature on %s', name, cmd.feature, net)
            return
        end
    end

    local params = {}
    if not cmd.pattern(args, params) then
        log.add('error', '%s requires: %s', name, cmd.spec)
        return
    end

    log.dismiss()
    local ctx = {net = net, target = net and control.talk_target(net)}
    local ok, err = xpcall(cmd.fn, traceback, ctx, table.unpack(params))
    if not ok then
        log.error(name, err)
    end
end

--- A command can be used on the current network: it needs no feature, or
--- the network has it.
function M.available(cmd)
    if not cmd.feature then return true end
    local net = control.current_net()
    return net ~= nil and common.enabled(net, cmd.feature)
end

--- Command names starting with a prefix, sorted.
---@param seed string
---@return string[]
function M.complete(seed)
    local t = {}
    for k, cmd in pairs(HUB.current.commands) do
        if k:sub(1, #seed) == seed and M.available(cmd) then
            table.insert(t, k)
        end
    end
    table.sort(t)
    return t
end

return M
