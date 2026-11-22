-- MONITOR, shared: a nick is on the server's list while anything has a
-- reason to watch it. A reason is a name (chat's private buffers,
-- net/reclaim.lua's wanted nick); M.want adds one, M.release takes it
-- away, and the nick leaves the list with its last reason. Those that
-- watch need not know of one another.
--
-- The list is the connection's, and so are the reasons
-- (irc.monitor_wants): what wants a nick on every connection asks for it
-- again once registered.
--
-- A nick asked for with MONITOR + is listed once a 730 or 731 answers.
-- MONITOR - has no reply, so a nick whose last reason goes before its
-- answer stays until the answer and is taken off then; taken off sooner,
-- the answer would put it back in the model. A nick refused for a full
-- list (734) is asked for again when another is taken off.
--
-- Only nicks asked for here are followed: the model's irc.monitor holds
-- their presence, and replies about any other nick are ignored.

local irc_model <const> = require 'hub.net.irc'
local N         <const> = require 'hub.lib.numerics'
local send      <const> = require 'hub.net.send'

local M = {}

-- Nicks per MONITOR + line are joined until the list passes this many
-- bytes, leaving room for the command in a 512-byte line
local line_budget <const> = 400

---@class hub.MonitorWant
---@field nick string as asked for
---@field reasons table<string, true> what watches it
---@field state 'asked'|'listed'|'full' asked with no answer yet, on the
--- server's list, or refused for a full list

-- The connection when it can take MONITOR now
---@param net string
---@return hub.Irc|nil
local function usable(net)
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    if irc and rec.phase == 'connected' and irc_model.has_monitor(irc) then
        return irc
    end
end

---@param irc hub.Irc
---@return table<string, hub.MonitorWant>
local function wants_of(irc)
    local wants = irc.monitor_wants
    if wants == nil then
        wants = {}
        irc.monitor_wants = wants
    end
    return wants
end

-- MONITOR + for nicks, in as few lines as fit
local function ask(net, nicks)
    local line, size = {}, 0
    for _, nick in ipairs(nicks) do
        table.insert(line, nick)
        size = size + #nick + 1
        if size > line_budget then
            send.send(net, 'MONITOR', '+', table.concat(line, ','))
            line, size = {}, 0
        end
    end
    if #line > 0 then
        send.send(net, 'MONITOR', '+', table.concat(line, ','))
    end
end

-- A place on the list came free: ask again for the nicks refused for a
-- full one
local function retry_full(net, irc)
    local nicks = {}
    for _, want in pairs(wants_of(irc)) do
        if want.state == 'full' then
            want.state = 'asked'
            table.insert(nicks, want.nick)
        end
    end
    ask(net, nicks)
end

-- Take a listed nick off the server's list and out of the model
local function unlist(net, irc, nick)
    irc_model.del_monitor(irc, nick)
    if HUB.state.nets[net].phase ~= 'connected' then return end
    send.send(net, 'MONITOR', '-', nick)
    retry_full(net, irc)
end

--- Watch nicks for a reason, asking the server for those not yet asked
--- for. A nick already listed is in the model now (irc_model.get_monitor).
--- Nothing is kept while the connection can't take MONITOR.
---@param net string
---@param reason string
---@param nicks string[]
function M.want_all(net, reason, nicks)
    local irc = usable(net)
    if not irc then return end
    local wants = wants_of(irc)
    local new = {}
    for _, nick in ipairs(nicks) do
        local key = irc_model.fold(irc, nick)
        local want = wants[key]
        if want == nil then
            want = {nick = nick, reasons = {}, state = 'asked'}
            wants[key] = want
            table.insert(new, nick)
        end
        want.reasons[reason] = true
    end
    ask(net, new)
end

---@param net string
---@param reason string
---@param nick string
function M.want(net, reason, nick)
    M.want_all(net, reason, {nick})
end

--- Stop watching a nick for a reason. Its last reason gone, it leaves the
--- list now, or on its answer when that hasn't come yet.
---@param net string
---@param reason string
---@param nick string
function M.release(net, reason, nick)
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    local wants = irc and irc.monitor_wants
    if not wants then return end
    ---@cast irc -nil
    local key = irc_model.fold(irc, nick)
    local want = wants[key]
    if not (want and want.reasons[reason]) then return end
    want.reasons[reason] = nil
    if next(want.reasons) ~= nil or want.state == 'asked' then return end
    wants[key] = nil
    if want.state == 'listed' then
        unlist(net, irc, nick)
    end
end

--- The reasons a nick is watched for, or nil when it isn't.
---@param irc hub.Irc
---@param nick string
---@return table<string, true>|nil
function M.reasons(irc, nick)
    local want = irc.monitor_wants and irc.monitor_wants[irc_model.fold(irc, nick)]
    return want and want.reasons
end

-- The nicks of a MONITOR reply's list: nick[!user@host],...
local function each_nick(list)
    return (list or ''):gmatch '([^!,]+)[^,]*,?'
end

--- A 730 or 731 (an answer, or a later change of presence) or a 734,
--- for the nicks asked for here.
---@param net string
---@param irc hub.Irc
---@param msg hub.Message
function M.on_reply(net, irc, msg)
    local wants = irc.monitor_wants
    if not (wants and irc_model.has_monitor(irc)) then return end
    local full = msg.command == N.ERR_MONLISTFULL
    local online = msg.command == N.RPL_MONONLINE
    local freed = false
    for nick in each_nick(full and msg[3] or msg[2]) do
        local key = irc_model.fold(irc, nick)
        local want = wants[key] -- nil: not ours
        local unwanted = want and next(want.reasons) == nil
        if want and full then
            if want.state == 'asked' then
                if unwanted then
                    wants[key] = nil
                else
                    want.state = 'full'
                end
            end
        elseif unwanted then
            -- its last reason went before this answer
            wants[key] = nil
            send.send(net, 'MONITOR', '-', nick)
            freed = true
        elseif want then
            want.state = 'listed'
            irc_model.add_monitor(irc, nick, online)
        end
    end
    if freed then retry_full(net, irc) end
end

return M
