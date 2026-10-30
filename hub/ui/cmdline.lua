-- Running a command typed on the command line.

local common    <const> = require 'hub.features.common'
local control   <const> = require 'hub.ui.control'
local log       <const> = require 'hub.runtime.log'
local traceback <const> = require 'hub.lib.traceback'

local M = {}

--- Parse and run one command line (without the leading slash).
---@param text string
function M.execute(text)
    local word, args = text:match '^ *(%g*) *(.*)$'
    -- a net command may name its network: /quote@libera ...
    local name, at = word:match '^([^@]*)@(.*)$'
    name = name or word
    local cmd = HUB.current.commands[name]
    if cmd == nil then
        log.add('error', 'unknown command: %s', name)
        return
    end

    local net = control.current_net()
    if at and cmd.scope ~= 'net' then
        log.add('error', '%s takes no network', name)
        return
    end
    if cmd.scope == 'net' then
        if at then
            if not HUB.state.nets[at] then
                log.add('error', 'no such network: %s', at)
                return
            end
            net = at
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
        if cmd.usage then
            log.add('error', 'usage: /%s %s', name, cmd.usage)
        else
            log.add('error', '/%s takes no arguments', name)
        end
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

--- Command names starting with a prefix, sorted; after name@, the
--- network ids for a net command.
---@param seed string
---@return string[]
function M.complete(seed)
    local t = {}
    local name, at = seed:match '^([^@]*)@(.*)$'
    if name then
        local cmd = HUB.current.commands[name]
        if cmd and cmd.scope == 'net' then
            for id in pairs(HUB.state.nets) do
                if id:sub(1, #at) == at then
                    table.insert(t, name .. '@' .. id)
                end
            end
        end
        table.sort(t)
        return t
    end
    for k, cmd in pairs(HUB.current.commands) do
        if k:sub(1, #seed) == seed and M.available(cmd) then
            table.insert(t, k)
        end
    end
    table.sort(t)
    return t
end

return M
