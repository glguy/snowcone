-- The command line's commands (commands/run.lua) act on the current
-- network and the buffer shown for it, and /addwatch and /editwatch can
-- take the cliconn view's filter.

local control <const> = require 'hub.ui.control'
local run     <const> = require 'hub.commands.run'
local usage   <const> = require 'hub.lib.usage'

local M = {}

---@param ctx hub.CommandContext
local function context(ctx)
    ctx.target = ctx.net and control.talk_target(ctx.net)
    ctx.filter = control.filter 'cliconn'
end

---@return hub.CommandOrigin
local function origin()
    return {net = control.current_net(), context = context}
end

--- Parse and run one command line (without the leading slash).
---@param text string
function M.execute(text)
    run.execute(text, origin())
end

--- A command can be used on the current network.
function M.available(cmd)
    return run.available(cmd, control.current_net())
end

--- Command names starting with a prefix, sorted; after name@, the
--- network ids for a net command.
---@param seed string
---@return string[]
function M.complete(seed)
    return run.complete(seed, control.current_net())
end

--- Tab's candidates for a command's argument, or nil for the default.
---@param prefix string the line before the word being completed
---@param seed string the start of that word
---@return string[]|nil
function M.complete_args(prefix, seed)
    return run.complete_args(prefix, seed, origin())
end

-- Some key of t starts with seed
local function starts_some(t, seed)
    for k in pairs(t) do
        if k:sub(1, #seed) == seed then return true end
    end
    return false
end

--- How a command line being typed is shown.
---
--- spans cover the line in order, each a role:
--- - plain: as typed, in the input color
--- - good: a command that can be used here, or the network it names
--- - warn: a command that can't be used on this network
--- - bad: an unknown command or network, a word that doesn't fit, or
---   words left over
--- - sep: the spaces between arguments, shown as a bar and the rest
--- - text: message text, with its formatting and spelling
---
--- The word the cursor is in, or at either end of, is shown plain rather
--- than bad while it could still become right. ghosts are the placeholders of
--- the arguments not yet typed, shown after the line; ghost_sep, that a
--- bar goes before the first, as the line doesn't end in a space.
---@class hub.CommandLook
---@field spans {lo: integer, hi: integer, role: string}[]
---@field ghosts hub.Placeholder[]
---@field ghost_sep boolean
---@field net string|nil the network the command acts on

--- What a command's shape(ctx, rest, slot, before) returns for the rest
--- of its line, before being the arguments ahead of it as typed: its
--- words, by byte within the rest, each shown apart and red when
--- it doesn't fit, and the placeholders still to come, from slot (the
--- rest's placeholders, lib/usage) or of its own. Words that touch show
--- as one, so a word can be red in part. A word that doesn't fit is
--- plain while the cursor is in it, unless final: no more typing at its
--- end would make it fit.
---@class hub.CommandShape
---@field words {lo: integer, hi: integer, ok: boolean, final: boolean|nil}[]
---@field ghosts hub.Placeholder[]

---@param text string the line, without the leading slash
---@param cursor integer bytes before the cursor
---@return hub.CommandLook
function M.decorate(text, cursor)
    local look = {spans = {}, ghosts = {}, ghost_sep = false}
    local function span(lo, hi, role)
        if lo <= hi then table.insert(look.spans, {lo = lo, hi = hi, role = role}) end
    end
    local function typing(lo, hi) return cursor >= lo - 1 and cursor <= hi end

    local line = run.split(text)
    local name_hi = line.name_lo + #line.name - 1
    span(1, line.name_lo - 1, 'plain')
    if line.name == '' and not line.at then
        span(line.name_lo, #text, 'plain')
        return look
    end

    local net = control.current_net()
    local cmd = HUB.current.commands[line.name]
    if not cmd then
        -- the whole word, a network it names and all
        local word_end = line.at and line.at_lo + #line.at - 1 or name_hi
        local maybe = line.at == nil and typing(line.name_lo, name_hi)
            and starts_some(HUB.current.commands, line.name)
        span(line.name_lo, word_end, maybe and 'plain' or 'bad')
        span(word_end + 1, #text, 'plain')
        return look
    end

    local word_hi, at_role = name_hi, nil
    if line.at then
        word_hi = line.at_lo + #line.at - 1
        local nets = HUB.state.nets or {}
        local role
        if cmd.scope ~= 'net' then
            role = 'bad'
        elseif nets[line.at] then
            role = 'good'
            net = line.at
        elseif typing(line.at_lo, word_hi) and starts_some(nets, line.at) then
            role = 'plain'
        else
            role = 'bad'
        end
        at_role = role
    end
    if cmd.scope ~= 'net' then net = nil end
    look.net = net

    local usable = run.available(cmd, net) and (cmd.scope ~= 'net' or net ~= nil)
    span(line.name_lo, name_hi, usable and 'good' or 'warn')
    if line.at then span(line.at_lo - 1, word_hi, at_role) end

    local ctx = {net = net}
    context(ctx)

    -- the arguments' words, then what is left over, in place in the line;
    -- a word naming nothing there is (cmd.exists) is as one that doesn't fit
    local shift = line.args_lo - 1
    local a = cmd.analyze(line.args)
    local pieces = {}
    for i, w in ipairs(a.words) do
        local item = a.items[i]
        local lo, hi = w.lo + shift, w.hi + shift
        local fits = w.ok
        if fits and usable and cmd.exists and not item.rest then
            fits = cmd.exists(ctx, i, text:sub(lo, hi))
        end
        local role = 'plain'
        if item.text then
            role = 'text'
        elseif not fits and not typing(lo, hi) then
            role = 'bad'
        end
        table.insert(pieces, {lo = lo, hi = hi, role = role})
    end
    if a.leftover then
        table.insert(pieces, {lo = a.leftover.lo + shift, hi = a.leftover.hi + shift, role = 'bad'})
    end

    -- a command that shapes the rest of its line says how it divides and
    -- what is still to come, where it can be used
    local pending
    local n = #a.items
    if cmd.shape and usable and n > 0 and a.items[n].rest and #a.words >= n - 1 then
        local w = a.words[n]
        if w then table.remove(pieces) end
        local rest = w and line.args:sub(w.lo, w.hi) or ''
        local base = (w and w.lo + shift or #text + 1) - 1
        local before = {}
        for i = 1, n - 1 do before[i] = line.args:sub(a.words[i].lo, a.words[i].hi) end
        local shape = cmd.shape(ctx, rest, cmd.slots and cmd.slots[n] or {}, before)
        for _, p in ipairs(shape.words) do
            local lo, hi = p.lo + base, p.hi + base
            local role = a.items[n].text and 'text' or 'plain'
            if not p.ok and (p.final or not typing(lo, hi)) then role = 'bad' end
            table.insert(pieces, {lo = lo, hi = hi, role = role})
        end
        pending = shape.ghosts
    else
        pending = cmd.slots and usage.pending(cmd.slots, a, line.args) or {}
    end
    local at = word_hi + 1
    for _, piece in ipairs(pieces) do
        span(at, piece.lo - 1, 'sep')
        span(piece.lo, piece.hi, piece.role)
        at = piece.hi + 1
    end
    -- the spaces at the end lead to the placeholders, if any
    span(at, #text, pending[1] and 'sep' or 'plain')
    look.ghosts = pending
    look.ghost_sep = pending[1] ~= nil and text:sub(-1) ~= ' '
    return look
end

return M
