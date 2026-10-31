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

--- Tab's candidates for a command's argument, from the command's
--- complete function; nil when it has none or offers none, for the
--- caller's default.
---@param prefix string the line before the word being completed
---@param seed string the start of that word
---@return string[]|nil
function M.complete_args(prefix, seed)
    local word, before = prefix:match '^ *(%g+) +(.*)$'
    if not word then return nil end
    local name, at = word:match '^([^@]*)@(.*)$'
    local cmd = HUB.current.commands[name or word]
    if not (cmd and cmd.complete) then return nil end
    local net = control.current_net()
    if cmd.scope == 'net' then
        net = at or net
        if not (net and HUB.state.nets[net]) then return nil end
        if cmd.feature and not common.enabled(net, cmd.feature) then return nil end
    end
    local ctx = {net = net, target = net and control.talk_target(net)}
    return cmd.complete(ctx, before, seed)
end

return M
