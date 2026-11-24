-- Taking back the wanted nick while the connection is on another.
--
-- irc.recover_nick is the nick to take back, as given. While it is set on
-- a registered connection with `reclaim_nick` on, a task watches for the
-- nick to come free and sends NICK for it. The task exists only while
-- reclaiming: M.start begins it, and it is canceled when we get the nick
-- or stop wanting it (M.stop), or when the connection ends. With
-- `reclaim_nick` off the nick is still recorded, but never taken.
--
-- The nick is watched with MONITOR while reclaiming (net/monitor.lua, as
-- 'reclaim'). It comes free when MONITOR reports it offline, when whoever holds
-- it quits or changes nick in a channel we share, or when a server notice
-- says so (M.attempt, from features/snotice). A refusal that only
-- holds for a while is tried again later:
--   437  held: nick delay after a netsplit, or services' NICKDELAY; a
--        delay that doubles with each refusal on the connection
--   435  we are banned or quieted in a channel; the same delay
--   438  too many nick changes; once the wait the server names is over.
--        Solanum counts refused changes too, so nothing goes out before.
-- 433 means someone has the nick again, and the task waits for it to come
-- free. 432 means the server won't take it at all, and reclaiming stops.

local clock     <const> = require 'hub.runtime.clock'
local irc_model <const> = require 'hub.net.irc'
local monitor   <const> = require 'hub.net.monitor'
local N         <const> = require 'hub.lib.numerics'
local send      <const> = require 'hub.net.send'
local task      <const> = require 'hub.runtime.task'

local M = {}

-- The first wait after a 437 or 435, in seconds, and the longest
local first_delay <const> = 30
local max_delay <const> = 600

-- After a NICK with no reply, how long until another may go, in seconds
local reply_wait <const> = 10

---@class hub.Reclaim
---@field task integer|nil the id of the task, while reclaiming
---@field held_until number|nil clock.now() before which no NICK goes out
---@field sent_at number|nil clock.now() of a NICK still waiting for its reply
---@field delay number the wait after the next 437 or 435, in seconds

---@param irc hub.Irc
---@return hub.Reclaim
local function state(irc)
    local r = irc.reclaim
    if r == nil then
        r = {delay = first_delay}
        irc.reclaim = r
    end
    return r
end

-- Whether a numeric names the nick among its parameters: past our own
-- nick, before the text. Servers differ in where they put it (Solanum's
-- 438 repeats our nick before it).
local function names(irc, msg, nick)
    local key = irc_model.fold(irc, nick)
    for i = 2, #msg - 1 do
        if irc_model.fold(irc, msg[i]) == key then return true end
    end
    return false
end

--- Send NICK for the nick being reclaimed, unless reclaiming is off, the
--- server asked us to wait, or a NICK for it is still unanswered. Features
--- that see the nick come free (server notices) call it too.
---@param net string
---@return boolean # whether a NICK went out
function M.attempt(net)
    local rec = HUB.state.nets[net]
    local irc = rec and rec.irc
    if not (irc and irc.recover_nick and rec.cfg.reclaim_nick and rec.phase == 'connected') then
        return false
    end
    local r = state(irc)
    local now = clock.now()
    if r.held_until and now < r.held_until then return false end
    if r.sent_at and now - r.sent_at < reply_wait then return false end
    r.held_until = nil
    r.sent_at = now
    send.send(net, 'NICK', irc.recover_nick)
    return true
end

-- Hold back after a refusal that lasts a while
local function hold(t, r, nick, seconds, why)
    r.sent_at = nil
    r.held_until = clock.now() + seconds
    t:log('irc', 'nick %s %s; trying again in %d s', nick, why, seconds)
end

local watched <const> = {
    N.RPL_MONOFFLINE, 'QUIT', 'NICK',
    N.ERR_NICKNAMEINUSE, N.ERR_UNAVAILRESOURCE, N.ERR_BANNICKCHANGE,
    N.ERR_NICKTOOFAST, N.ERR_ERRONEUSNICKNAME,
}

---@param t hub.Task
---@param nick string
local function run(t, nick)
    local rec = HUB.state.nets[t.net]
    local irc = rec.irc
    local r = state(irc)
    local key = irc_model.fold(irc, nick)

    -- the reply says whether the nick is free now. A nick already watched
    -- for another reason gets none: known to be offline, it is tried at
    -- once, though only after any refusal that started this reclaim,
    -- which comes to the first wait before its timeout can.
    monitor.want(t.net, 'reclaim', nick)
    local known = irc_model.get_monitor(irc, nick)
    local first_ms = known and not known.user and 0 or nil

    while true do
        local timeout_ms = first_ms
        first_ms = nil
        if r.held_until then
            timeout_ms = math.max(0, math.ceil((r.held_until - clock.now()) * 1000))
        end
        local msg = t:wait_irc(watched, timeout_ms)
        local command = msg and msg.command
        if msg == nil then
            r.held_until = nil
            M.attempt(t.net)
        elseif command == N.RPL_MONOFFLINE then
            for offline in (msg[2] or ''):gmatch '([^!,]+)[^,]*,?' do
                if irc_model.fold(irc, offline) == key then
                    M.attempt(t.net)
                end
            end
        elseif command == 'QUIT' then
            if msg.nick and irc_model.fold(irc, msg.nick) == key then
                M.attempt(t.net)
            end
        elseif command == 'NICK' then
            -- its holder let it go; a change of case keeps it
            local new = msg[1]
            if msg.nick and new and irc_model.fold(irc, msg.nick) == key
               and irc_model.fold(irc, new) ~= key and not irc_model.is_me(irc, new) then
                M.attempt(t.net)
            end
        elseif names(irc, msg, nick) then
            if command == N.ERR_NICKNAMEINUSE then
                r.sent_at = nil -- taken again: wait for it to come free
            elseif command == N.ERR_UNAVAILRESOURCE or command == N.ERR_BANNICKCHANGE then
                hold(t, r, nick, r.delay, command == N.ERR_BANNICKCHANGE
                    and 'refused while banned in a channel' or 'held by the server')
                r.delay = math.min(r.delay * 2, max_delay)
            elseif command == N.ERR_NICKTOOFAST then
                local wait = tonumber(msg[#msg]:match '(%d+) second') or 20
                hold(t, r, nick, wait + 1, 'refused: changing nick too fast')
            elseif command == N.ERR_ERRONEUSNICKNAME then
                t:log('irc', 'nick %s refused as erroneous; no longer reclaiming it', nick)
                M.stop(rec, irc)
            end
        end
    end
end

--- Reclaim a nick: record it, as the server would take it, and once
--- registered start the task. A reclaim already under way for it carries
--- on; one for another nick stops first.
---@param rec hub.Network
---@param irc hub.Irc
---@param nick string
function M.start(rec, irc, nick)
    nick = irc_model.cut_nick(irc, nick)
    if irc.recover_nick and irc_model.fold(irc, irc.recover_nick) ~= irc_model.fold(irc, nick) then
        M.stop(rec, irc)
    end
    irc.recover_nick = nick
    if not (rec.cfg.reclaim_nick and rec.phase == 'connected') then return end
    local r = state(irc)
    if r.task and HUB.tasks[r.task] then return end
    r.task = task.spawn('nick recovery', {net = rec.id, owner = 'net'}, run, nick).id
end

--- Stop reclaiming: we have the nick, or it is no longer wanted.
---@param rec hub.Network
---@param irc hub.Irc
function M.stop(rec, irc)
    local nick = irc.recover_nick
    if nick == nil then return end
    irc.recover_nick = nil
    local r = state(irc)
    r.held_until, r.sent_at = nil, nil
    if r.task then
        local id = r.task
        r.task = nil
        task.cancel(id)
    end
    monitor.release(rec.id, 'reclaim', nick)
end

return M
