-- Running a command line, and Tab's candidates for one. Whoever has the
-- line says which network it acts on and adds what only it knows to the
-- context: the UI gives its current network and the buffer shown there;
-- a test or plugin may name them outright.

local common    <const> = require 'hub.features.common'
local log       <const> = require 'hub.runtime.log'
local traceback <const> = require 'hub.lib.traceback'

local M = {}

--- What a command's fn and complete get before their arguments.
---@class hub.CommandContext
---@field net string|nil the network a net command acts on
---@field target string|nil the buffer shown for that network, if any
---@field filter string|nil the cliconn view's filter, for /addwatch

--- Where a command line comes from.
---@class hub.CommandOrigin
---@field net string|nil the network a net command acts on unless it names one
---@field context fun(ctx: hub.CommandContext)|nil fills in the rest of the
--- context, such as `target`, once `ctx.net` is settled

---@param origin hub.CommandOrigin|nil
---@param net string|nil
---@return hub.CommandContext
local function context(origin, net)
    local ctx = {net = net}
    if origin and origin.context then origin.context(ctx) end
    return ctx
end

--- Parse and run one command line (without the leading slash).
---@param text string
---@param origin hub.CommandOrigin|nil
function M.execute(text, origin)
    local word, args = text:match '^ *(%g*) *(.*)$'
    -- a net command may name its network: /quote@libera ...
    local name, at = word:match '^([^@]*)@(.*)$'
    name = name or word
    local cmd = HUB.current.commands[name]
    if cmd == nil then
        log.add('error', 'unknown command: %s', name)
        return
    end

    local net = origin and origin.net
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
    local ok, err = xpcall(cmd.fn, traceback, context(origin, net), table.unpack(params))
    if not ok then
        log.error(name, err)
    end
end

--- A command can be used on a network: it needs no feature, or the
--- network has it.
---@param cmd table
---@param net string|nil
---@return boolean
function M.available(cmd, net)
    if not cmd.feature then return true end
    return net ~= nil and common.enabled(net, cmd.feature)
end

--- Command names starting with a prefix that can be used on a network,
--- sorted; after name@, the network ids for a net command.
---@param seed string
---@param net string|nil
---@return string[]
function M.complete(seed, net)
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
        if k:sub(1, #seed) == seed and M.available(cmd, net) then
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
---@param origin hub.CommandOrigin|nil
---@return string[]|nil
function M.complete_args(prefix, seed, origin)
    local word, before = prefix:match '^ *(%g+) +(.*)$'
    if not word then return nil end
    local name, at = word:match '^([^@]*)@(.*)$'
    local cmd = HUB.current.commands[name or word]
    if not (cmd and cmd.complete) then return nil end
    local net = origin and origin.net
    if cmd.scope == 'net' then
        net = at or net
        if not (net and HUB.state.nets[net]) then return nil end
        if cmd.feature and not common.enabled(net, cmd.feature) then return nil end
    end
    return cmd.complete(context(origin, net), before, seed)
end

return M
