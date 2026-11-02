-- Connection registration, run as a network task after CON.
--
-- CAP LS, PASS, NICK and USER go out together; the server holds
-- registration until CAP END, so SASL still happens first. A server
-- without CAP registers right away, and the RPL_WELCOME that ends LS is
-- used directly.

local cap       <const> = require 'hub.net.cap'
local clock     <const> = require 'hub.runtime.clock'
local config    <const> = require 'hub.runtime.config'
local irc_model <const> = require 'hub.net.irc'
local N         <const> = require 'hub.lib.numerics'
local oper      <const> = require 'hub.net.oper'
local secrets   <const> = require 'hub.runtime.secrets'

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

-- JOIN the configured channels, as many to a line as fit
local function join_channels(t, channels)
    local names, size = {}, 0
    for _, name in ipairs(channels) do
        if #names > 0 and size + #name > 400 then
            t:send('JOIN', table.concat(names, ','))
            names, size = {}, 0
        end
        table.insert(names, name)
        size = size + #name + 1
    end
    if #names > 0 then
        t:send('JOIN', table.concat(names, ','))
    end
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

    -- resolved before anything is sent, since it may prompt
    local ok, password = pcall(secrets.server_password, t, cfg.registration)
    if not ok then
        t:log('irc', 'Password resolution failed: %s', password)
        password = nil
    end

    local nick  = cfg.identity.nick
    local user  = cfg.identity.user  or nick
    local realname = cfg.identity.realname or nick

    t:send('CAP', 'LS', '302')
    if password then
        t:send('PASS', {content = password, secret = true})
    end
    t:send('NICK', nick)
    irc.nick = nick -- optimistic
    t:send('USER', user, '0', '*', realname)

    -- "<client> :Welcome to the <networkname> Network, <nick>[!<user>@<host>]"
    local welcome = cap.LS(t) or t:wait_irc {N.RPL_WELCOME}
    irc.nick = welcome[1] -- first confirmation

    -- "<client> :End of /MOTD command."
    -- "<client> :MOTD File is missing"
    t:wait_irc {N.RPL_ENDOFMOTD, N.ERR_NOMOTD}

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
        t:send('MONITOR', '+', cfg.identity.nick)
    end

    -- before opering, which may wait on a CHALLENGE reply
    if cfg.channels then
        join_channels(t, cfg.channels)
    end

    oper_up(t, cfg)
end
