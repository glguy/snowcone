-- Ban workflow: stage a K-Line, unkline or undline, see how many users it
-- matches, then send it.
--
-- K-Line reasons and tags come from the network's servers file
-- (runtime/config.lua). Staging sends only queries (TESTMASK, TESTKLINE,
-- WHO, WHOWAS); KLINE, UNKLINE, UNDLINE and NickServ FREEZE go out only
-- from commit, which the UI calls when the operator confirms.

local challenge  <const> = require 'hub.net.challenge'
local common     <const> = require 'hub.features.common'
local irc_model  <const> = require 'hub.net.irc'
local log        <const> = require 'hub.runtime.log'
local masks      <const> = require 'hub.features.oper.masks'
local N          <const> = require 'hub.lib.numerics'
local OrderedMap <const> = require 'hub.lib.OrderedMap'
local secrets    <const> = require 'hub.runtime.secrets'
local send       <const> = require 'hub.net.send'
local stores     <const> = require 'hub.features.snotice.stores'
local task       <const> = require 'hub.runtime.task'

local M = {}

M.name = 'oper'

--- K-Line durations offered by the duration button
M.durations = {'4h', '1d', '3d'}

--- A staged ban. count comes from TESTMASK.
---@class hub.Staged
---@field action 'kline'|'unkline'|'undline'
---@field mask string|nil
---@field nick string|nil
---@field user string|nil
---@field host string|nil
---@field ip string|nil
---@field count integer|nil

---@class hub.OperSettings
---@field duration string
---@field reason integer index into the servers file's kline_reasons
---@field tag string|nil
---@field trust_uname boolean
---@field add_freeze boolean
---@field tags string[] extra tags added with /tag

--- A network's ban workflow, state.features.oper[net].
---@class hub.OperState
---@field staged hub.Staged|nil
---@field settings hub.OperSettings

---@return hub.OperState
local function new_state()
    return {
        staged = nil,
        settings = {duration = '1d', reason = 1, tag = nil, trust_uname = false, add_freeze = false, tags = {}},
    }
end

---@param net string
---@return hub.OperState
function M.get(net)
    return common.net_state(M.name, net, new_state)
end

local function query(net, ...)
    local ok, err = pcall(send.send, net, ...)
    if not ok then
        log.add_net(net, 'oper', '%s', err)
    end
    return ok
end

-- Durations ===========================================================

local units <const> = {m = 1, h = 60, d = 1440, w = 10080, M = 43200, Y = 525600}

--- Minutes in a duration like '1d', '4h', '1w 2d', or nil if it doesn't
--- parse.
function M.parse_duration(str)
    local acc = 0
    local leftover = str:gsub(' *(%-?%d+) *([mhdwMY]) *', function(n, u)
        acc = acc + math.tointeger(n) * units[u]
        return ''
    end)
    if leftover == '' then
        return acc
    end
end

--- A duration in minutes for display: '45m', '1.5 h', '3.0 d'.
function M.pretty_duration(minutes)
    local m = tonumber(minutes)
    if not m then return minutes end
    if m >= 1440 then return string.format('%.1f d', m / 1440) end
    if m >= 60 then return string.format('%.1f h', m / 60) end
    return m .. 'm'
end

-- Reasons and tags ====================================================

-- Offered when the servers file gives no reasons
local default_reasons <const> = {{'banned', 'You are banned.'}}

--- The reasons offered: {label, text} pairs from the servers file, or a
--- default when it gives none (an empty list would leave nothing to send).
function M.reasons(net)
    local reasons = common.servers(net).kline_reasons
    if type(reasons) ~= 'table' or #reasons == 0 then
        return default_reasons
    end
    return reasons
end

--- The tags offered: the servers file's, then those added with /tag.
function M.tags(net)
    local list = {}
    for _, t in ipairs(common.servers(net).kline_tags or {}) do
        table.insert(list, t)
    end
    for _, t in ipairs(M.get(net).settings.tags) do
        table.insert(list, t)
    end
    return list
end

--- The K-Line reason text to send, with the tag added.
function M.reason_text(net)
    local settings = M.get(net).settings
    local reasons = M.reasons(net)
    local entry = reasons[settings.reason] or reasons[1]
    local reason = entry[2]
    local tag = settings.tag
    if tag then
        if reason:find '|' then
            reason = reason .. ' %' .. tag
        else
            reason = reason .. '|%' .. tag
        end
    end
    return reason
end

-- Staging =============================================================

--- Stage a K-Line for a user and ask how many users it matches.
function M.prepare_kline(net, nick, user, host, ip)
    local O = M.get(net)
    local ok, mask = pcall(masks, user, ip, host, O.settings.trust_uname)
    if not ok then
        log.add_net(net, 'kline', '%s', mask)
        O.staged = nil
        return
    end
    O.staged = {action = 'kline', mask = mask, nick = nick, user = user, host = host, ip = ip}
    query(net, 'TESTMASK', mask)
end

--- Stage a K-Line for a connection entry from the notice stores.
function M.entry_to_kline(net, entry)
    M.prepare_kline(net, entry.nick, entry.user, entry.host, entry.ip)
end

--- Stage removing the K-Line that hit a user; TESTKLINE finds its mask.
function M.entry_to_unkline(net, entry)
    local O = M.get(net)
    if not entry.ip then
        log.add_net(net, 'unkline', 'no address known for %s', entry.nick)
        return
    end
    local probe = entry.user .. '@' .. entry.ip
    local staged = {action = 'unkline', nick = entry.nick}
    O.staged = staged
    task.spawn('unkline lookup', {net = net, owner = M.name}, function(t)
        t:send('TESTKLINE', probe)
        while true do
            local msg = t:wait_irc({N.RPL_NOTESTLINE, N.RPL_TESTLINE}, 30000)
            if M.get(t.net).staged ~= staged then return end -- replaced meanwhile
            if not msg then
                M.get(t.net).staged = nil
                return
            elseif msg.command == N.RPL_NOTESTLINE and msg[2] == probe then
                M.get(t.net).staged = nil
                return
            elseif msg.command == N.RPL_TESTLINE and msg[2] == 'k' then
                staged.mask = msg[4]
                return
            end
        end
    end)
end

--- Stage removing a K-Line by mask (from the bans view).
function M.stage_unkline(net, mask)
    M.get(net).staged = {action = 'unkline', mask = mask}
    query(net, 'TESTLINE', mask)
end

--- Stage removing a D-Line by mask.
function M.stage_undline(net, mask)
    M.get(net).staged = {action = 'undline', mask = mask}
end

function M.cancel(net)
    M.get(net).staged = nil
end

--- The staged action is complete enough to send.
function M.ready(net)
    local staged = M.get(net).staged
    return staged ~= nil and staged.mask ~= nil
end

--- The account to freeze with a staged K-Line: when freezing is on, a tag
--- is chosen and the user's connection recorded an account.
function M.freeze_account(net)
    local O = M.get(net)
    local staged = O.staged
    if not (staged and staged.action == 'kline' and O.settings.add_freeze and O.settings.tag and staged.nick) then
        return nil
    end
    local user = OrderedMap.lookup(stores.get(net).users, staged.nick)
    local account = user and user.account
    if account and account ~= '*' then
        return account
    end
end

--- MASKTRACE the staged mask, to see who it would hit.
function M.trace(net)
    local staged = M.get(net).staged
    if staged and staged.mask then
        send.send(net, 'MASKTRACE', staged.mask)
    end
end

--- Send the staged action.
function M.commit(net)
    local O = M.get(net)
    local staged = O.staged
    if not (staged and staged.mask) then
        error('nothing ready to send', 0)
    end
    if staged.action == 'kline' then
        local freeze = M.freeze_account(net)
        send.send(net, 'KLINE', M.parse_duration(O.settings.duration), staged.mask, M.reason_text(net))
        if freeze then
            send.send(net, 'NS', 'FREEZE', freeze, 'ON', '%' .. O.settings.tag)
        end
    elseif staged.action == 'unkline' then
        send.send(net, 'UNKLINE', staged.mask)
    elseif staged.action == 'undline' then
        send.send(net, 'UNDLINE', staged.mask)
    end
    O.staged = nil
end

-- Settings ============================================================

--- Step through the offered durations (backwards when shifted).
function M.cycle_duration(net, back)
    local settings = M.get(net).settings
    local i = 0
    for k, d in ipairs(M.durations) do
        if d == settings.duration then i = k end
    end
    settings.duration = M.durations[(i + (back and -2 or 0)) % #M.durations + 1]
end

function M.cycle_reason(net, back)
    local settings = M.get(net).settings
    local n = #M.reasons(net)
    settings.reason = (settings.reason + (back and -2 or 0)) % n + 1
end

--- Step through the tags and no tag.
function M.cycle_tag(net, back)
    local settings = M.get(net).settings
    local tags = M.tags(net)
    local i = 0
    for k, t in ipairs(tags) do
        if t == settings.tag then i = k end
    end
    i = (i + (back and -1 or 1)) % (#tags + 1)
    settings.tag = tags[i]
end

--- Toggle trusting unidented usernames, restaging a staged K-Line.
function M.toggle_trust(net)
    local O = M.get(net)
    O.settings.trust_uname = not O.settings.trust_uname
    local staged = O.staged
    if staged and staged.action == 'kline' and staged.user then
        M.prepare_kline(net, staged.nick, staged.user, staged.host, staged.ip)
    end
end

-- Replies =============================================================

-- "<client> <local> <remote> <mask> <gecos> :Local/remote clients match"
local function on_testmask(net, msg)
    local staged = M.get(net).staged
    local loc, rem, mask, gecos = msg[2], msg[3], msg[4], msg[5]
    if staged and staged.mask and gecos == '*' and mask == '*!' .. staged.mask then
        staged.count = (math.tointeger(loc) or 0) + (math.tointeger(rem) or 0)
    end
end

function M.subscribe(sub)
    sub.on('irc.message', function(ev)
        if ev.msg.command == N.RPL_TESTMASKGECOS and common.enabled(ev.net, M.name) then
            on_testmask(ev.net, ev.msg)
        end
    end)
    sub.on('net.removed', function(ev) common.drop_state(M.name, ev.net) end)
end

-- Commands ============================================================

-- Find a user that isn't in the connection store with WHO, then WHOWAS,
-- and stage a K-Line
local function kline_lookup(t, nick)
    local irc = HUB.state.nets[t.net].irc
    local key = irc_model.fold(irc, nick)
    local function same(n) return n and irc_model.fold(irc, n) == key end

    t:send('WHO', nick, '%tuihn,696')
    while true do
        local msg = t:wait_irc({N.RPL_WHOSPCRPL, N.RPL_ENDOFWHO}, 30000)
        if not msg then return t:log('kline', 'no WHO reply for %s', nick) end
        if msg.command == N.RPL_WHOSPCRPL and msg[2] == '696' and same(msg[6]) then
            return M.prepare_kline(t.net, msg[6], msg[3], msg[5], msg[4])
        elseif msg.command == N.RPL_ENDOFWHO and same(msg[2]) then
            break
        end
    end

    t:send('WHOWAS', nick, '1')
    local user, host, gecos
    while true do
        local msg = t:wait_irc({N.RPL_WHOWASUSER, N.ERR_WASNOSUCHNICK, N.RPL_ENDOFWHOWAS, N.RPL_WHOISACTUALLY}, 30000)
        if not msg then return t:log('kline', 'no WHOWAS reply for %s', nick) end
        local command = msg.command
        if command == N.RPL_WHOWASUSER and same(msg[2]) then
            -- "<client> <nick> <username> <host> * :<realname>"
            user, host, gecos = msg[3], msg[4], msg[6]
        elseif command == N.ERR_WASNOSUCHNICK and same(msg[2]) then
            return t:log('kline', 'Failed to find %s', msg[2])
        elseif command == N.RPL_ENDOFWHOWAS and same(msg[2]) then
            if user and host and gecos then
                -- no address: the mask comes from a gateway cloak or fails
                return M.prepare_kline(t.net, msg[2], user, host, '255.255.255.255')
            end
            return t:log('kline', 'Failed to find %s', msg[2])
        elseif command == N.RPL_WHOISACTUALLY and same(msg[2]) then
            if user and host and gecos then
                return M.prepare_kline(t.net, msg[2], user, host, msg[3])
            end
            return t:log('kline', 'Missing 314 response for %s', msg[2])
        end
    end
end

local function oper_command(name, spec, help, fn)
    return {name = name, spec = spec, scope = 'net', feature = M.name, help = help, fn = fn}
end

M.commands = {
    oper_command('kline_nick', '$g', 'Stage a K-Line for a nick, looking it up if needed', function(ctx, nick)
        local entry = common.enabled(ctx.net, 'snotice')
            and OrderedMap.lookup(stores.get(ctx.net).users, nick)
        if entry then
            M.entry_to_kline(ctx.net, entry)
        else
            task.spawn('kline lookup', {net = ctx.net, owner = M.name}, kline_lookup, nick)
        end
    end),
    oper_command('duration', '$r', 'Set the K-Line duration: 4h, 1d, 1w 2d ...', function(ctx, text)
        text = text:gsub(' +', '')
        local n = M.parse_duration(text)
        if not n or n <= 0 then
            error('bad duration: ' .. text, 0)
        end
        M.get(ctx.net).settings.duration = text
    end),
    oper_command('tag', '$g', 'Choose a K-Line tag, adding it if new', function(ctx, tag)
        local settings = M.get(ctx.net).settings
        local known = false
        for _, t in ipairs(M.tags(ctx.net)) do
            if t == tag then known = true end
        end
        if not known then
            table.insert(settings.tags, tag)
        end
        settings.tag = tag
    end),
    oper_command('droptag', '', 'Stop tagging, and forget the tag if /tag added it', function(ctx)
        local settings = M.get(ctx.net).settings
        for i, t in ipairs(settings.tags) do
            if t == settings.tag then
                table.remove(settings.tags, i)
                break
            end
        end
        settings.tag = nil
    end),
    oper_command('masktrace', '$g', 'MASKTRACE a mask', function(ctx, mask)
        send.send(ctx.net, 'MASKTRACE', mask)
    end),
    oper_command('testline', '$g', 'TESTLINE a mask', function(ctx, mask)
        send.send(ctx.net, 'TESTLINE', mask)
    end),
    oper_command('challenge', '', 'Become an operator with CHALLENGE', function(ctx)
        local cfg = HUB.state.nets[ctx.net].cfg.challenge
        if not cfg then
            error('no challenge configuration', 0)
        end
        task.spawn('challenge', {net = ctx.net, owner = M.name}, challenge, cfg)
    end),
    oper_command('oper', '', 'Become an operator with OPER', function(ctx)
        local cfg = HUB.state.nets[ctx.net].cfg.oper
        if not cfg then
            error('no oper configuration', 0)
        end
        task.spawn('oper', {net = ctx.net, owner = M.name}, function(t)
            local password = secrets.resolve(t, cfg.password)
            t:send('OPER', cfg.username, {content = password, secret = true})
        end)
    end),
}

return M
