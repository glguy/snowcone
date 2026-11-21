-- Connection registration, run as a network task after CON.
--
-- Capability negotiation runs as a task of its own (net/cap.lua). PASS,
-- NICK and USER go out right behind its CAP LS; the server holds
-- registration until CAP END, so SASL still happens first. Meanwhile
-- this task answers whatever refuses the registration, up to the
-- welcome; net/handlers.lua takes those numerics from there.

local cap       <const> = require 'hub.net.cap'
local clock     <const> = require 'hub.runtime.clock'
local config    <const> = require 'hub.runtime.config'
local handlers  <const> = require 'hub.net.handlers'
local intent    <const> = require 'hub.net.intent'
local irc_model <const> = require 'hub.net.irc'
local N         <const> = require 'hub.lib.numerics'
local oper      <const> = require 'hub.net.oper'
local secrets   <const> = require 'hub.runtime.secrets'

-- How long the end of MOTD may take after the welcome
local motd_timeout_ms <const> = 30000

-- What can come back to PASS, NICK and USER
local until_welcome <const> = {
    N.RPL_WELCOME,
    N.ERR_NICKNAMEINUSE,
    N.ERR_UNAVAILRESOURCE,
    N.ERR_ERRONEUSNICKNAME,
    N.ERR_PASSWDMISMATCH,
}

-- Wait for the welcome. A nick that is taken or held gets a random
-- replacement, and the wanted one is reclaimed later. A nick or password
-- the server refuses is a problem in the configuration: the network
-- gives up, and this returns nil.
---@param t hub.Task
---@param rec hub.Network
---@param irc hub.Irc
---@param wanted string
---@return hub.Message|nil # RPL_WELCOME
local function await_welcome(t, rec, irc, wanted)
    while true do
        local msg = t:wait_irc(until_welcome)
        local command = msg.command
        if command == N.RPL_WELCOME then
            -- "<client> :Welcome to the <networkname> Network, <nick>[!<user>@<host>]"
            return msg
        elseif command == N.ERR_NICKNAMEINUSE or command == N.ERR_UNAVAILRESOURCE then
            local nick = string.format('%s-%05d', wanted:sub(1, 10), math.random(0, 99999))
            t:send('NICK', nick)
            irc.recover_nick = wanted
            irc.nick = nick -- optimistic
        elseif command == N.ERR_ERRONEUSNICKNAME then
            -- a replacement can't know what the server wants
            local want = intent.of(rec)
            local field = want.nick and '/nick' or 'identity.nick'
            want.nick = nil -- the next connection tries the configured one
            t:api 'hub.net.manager'.give_up(t.net, string.format(
                '%s: the server refuses %s: %s', field, msg[2] or '?', msg[3] or 'erroneous nickname'))
            return nil
        else
            -- retrying with it could get us throttled
            t:api 'hub.net.manager'.give_up(t.net, string.format(
                'registration.password: the server refuses it: %s', msg[#msg] or 'password incorrect'))
            return nil
        end
    end
end

local function oper_up(t, cfg)
    if not oper.first(t, config.automatic_credentials(cfg.oper)) then
        -- learn our modes; also tells whether we're already oper
        t:send('MODE', HUB.state.nets[t.net].irc.nick)
    end
end

-- IRCv3 bot mode: the server names its letter in ISUPPORT BOT
local function bot_mode(t, irc)
    local letter = irc.isupport.BOT
    if type(letter) == 'string' and letter:match '^%a$' then
        t:send('MODE', irc.nick, '+' .. letter)
    else
        t:log('irc', 'identity.bot: the server names no bot mode')
    end
end

-- JOIN the channels the session wants (net/intent.lua), as many to a
-- line as fit. Keys pair with channels by position, so on each line the
-- channels with keys come first.
---@param channels hub.IntentChannel[]
local function join_channels(t, channels)
    local line, size = {}, 0
    local function flush()
        if #line == 0 then return end
        local names, keys = {}, {}
        for _, c in ipairs(line) do
            if c.key then
                table.insert(names, c.name)
                table.insert(keys, c.key)
            end
        end
        for _, c in ipairs(line) do
            if not c.key then table.insert(names, c.name) end
        end
        if #keys > 0 then
            t:send('JOIN', table.concat(names, ','), table.concat(keys, ','))
        else
            t:send('JOIN', table.concat(names, ','))
        end
        line, size = {}, 0
    end
    for _, channel in ipairs(channels) do
        local n = #channel.name + 1 + (channel.key and #channel.key + 1 or 0)
        if #line > 0 and size + n > 400 then flush() end
        table.insert(line, channel)
        size = size + n
    end
    flush()
end

---@param t hub.Task
return function(t)
    local rec <const> = HUB.state.nets[t.net]
    local cfg <const> = rec.cfg
    local irc <const> = rec.irc

    irc_model.configure_caps(irc, cfg.registration.capabilities)

    if cfg.sasl and cfg.sasl.automatic then
        irc.sasl_credentials = config.automatic_credentials(cfg.sasl)
    end

    -- prepared by the connect task before the connection opened
    local ok, password = pcall(secrets.server_password, t, cfg.registration)
    if not ok then
        t:log('irc', 'Password resolution failed: %s', password)
        password = nil
    elseif password and password:find '[\r\n%z]' then
        t:api 'hub.net.manager'.give_up(t.net, 'registration.password: a line break or NUL in it')
        return
    end

    local nick  = handlers.wanted_nick(rec)
    local user  = cfg.identity.user  or cfg.identity.nick
    local realname = cfg.identity.realname or cfg.identity.nick

    -- CAP LS goes out before spawn returns
    t:spawn('cap negotiation', cap.negotiate)
    if password then
        t:send('PASS', {content = password, secret = true})
    end
    t:send('NICK', nick)
    t:send('USER', user, '0', '*', realname)
    irc.nick = nick -- optimistic

    local welcome = await_welcome(t, rec, irc, nick)
    if not welcome then return end
    irc.nick = welcome[1] -- first confirmation

    -- "<client> :End of /MOTD command."
    -- "<client> :MOTD File is missing"
    -- A server that sends neither would hold the session back for good
    if not t:wait_irc({N.RPL_ENDOFMOTD, N.ERR_NOMOTD}, motd_timeout_ms) then
        t:log('irc', 'no end of MOTD after %d s; registered anyway', motd_timeout_ms // 1000)
    end

    -- before net.registered, so it precedes anything sent in reply to it
    if cfg.identity.bot then
        bot_mode(t, irc)
    end

    t:api 'hub.net.manager'.set_phase(t.net, 'connected')
    rec.registered_at = clock.now()
    t:log('irc', 'registered as %s', irc.nick)
    t:emit('net.registered', {net = t.net, nick = irc.nick})

    -- start waiting for our nickname
    if irc.recover_nick and cfg.reclaim_nick and irc_model.has_monitor(irc) then
        t:send('MONITOR', '+', irc.recover_nick)
    end

    -- before opering, which may wait on a CHALLENGE reply
    join_channels(t, intent.channels(rec, irc))
    local away = intent.of(rec).away
    if away then
        t:send('AWAY', away)
    end

    oper_up(t, cfg)
end
