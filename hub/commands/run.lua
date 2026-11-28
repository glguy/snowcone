-- Running a command line, and Tab's candidates for one. Whoever has the
-- line says which network it acts on and adds what only it knows to the
-- context: the UI gives its current network and the buffer shown there;
-- a test or plugin may name them outright.

local common    <const> = require 'hub.features.common'
local irc_param <const> = require 'hub.lib.irc_param'
local log       <const> = require 'hub.runtime.log'
local traceback <const> = require 'hub.lib.traceback'

local M = {}

--- What a command's fn and complete get before their arguments.
---@class hub.CommandContext
---@field net string|nil the network a net command acts on
---@field target string|nil the buffer shown for that network, if any
---@field filter string|nil the cliconn view's filter, for /addwatch and /editwatch

--- Tab's candidates for a command's argument: before is the arguments
--- before it, seed the start of it; nil for the default, channels and
--- nicks.
---@alias hub.Complete fun(ctx: hub.CommandContext, before: string, seed: string): string[]|nil

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

--- The parts of a command line (without the leading slash), with the
--- byte each starts at.
---@class hub.CommandLine
---@field name string the command's name
---@field name_lo integer
---@field at string|nil the network it names, after an @: /quote@libera ...
---@field at_lo integer|nil the byte after the @
---@field args string the arguments, from the first byte after the spaces
---@field args_lo integer

---@param text string
---@return hub.CommandLine
function M.split(text)
    local name_lo, word, args_lo, args = text:match '^ *()([^ ]*) *()(.*)$'
    local name, at = word:match '^([^@]*)@(.*)$'
    return {
        name = name or word, name_lo = name_lo,
        at = at, at_lo = at and name_lo + #name + 1,
        args = args, args_lo = args_lo,
    }
end

--- Parse and run one command line (without the leading slash).
---@param text string
---@param origin hub.CommandOrigin|nil
function M.execute(text, origin)
    local line = M.split(text)
    local name, at, args = line.name, line.at, line.args
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
        -- a word that can't go where it would is said outright
        local a = cmd.analyze(args)
        for i, w in ipairs(a.words) do
            if not w.ok and a.items[i].kind == 'a' then
                log.add('error', '/%s: %s', name, irc_param.not_middle(args:sub(w.lo, w.hi)))
                return
            end
        end
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
    local word, before = prefix:match '^ *([^ ]+) +(.*)$'
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
