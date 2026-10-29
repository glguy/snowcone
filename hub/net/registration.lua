-- Connection registration, run as a network task after CON.
--
-- CAP LS, PASS, NICK and USER go out together; the server holds
-- registration until CAP END, so SASL still happens first. A server
-- without CAP registers right away, and the RPL_WELCOME that ends LS is
-- used directly.

local cap       <const> = require 'hub.net.cap'
local challenge <const> = require 'hub.net.challenge'
local clock     <const> = require 'hub.runtime.clock'
local irc_model <const> = require 'hub.net.irc'
local N         <const> = require 'hub.lib.numerics'
local secrets   <const> = require 'hub.runtime.secrets'

local function oper_up(t, cfg)
    if cfg.challenge and cfg.challenge.automatic then
        challenge(t, cfg.challenge)
    elseif cfg.oper and cfg.oper.automatic then
        local password <const> = secrets.resolve(t, cfg.oper.password)
        t:send('OPER', cfg.oper.username, {content = password, secret = true})
    else
        -- learn our modes; also tells whether we're already oper
        t:send('MODE', HUB.state.nets[t.net].irc.nick)
    end
end

---@param t hub.Task
return function(t)
    local rec <const> = HUB.state.nets[t.net]
    local cfg <const> = rec.cfg
    local irc <const> = rec.irc

    irc_model.configure_caps(irc, cfg.server.capabilities)

    if cfg.sasl and cfg.sasl.automatic then
        local credentials = {}
        for _, name in ipairs(cfg.sasl.automatic) do
            local credential = secrets.get_credential(cfg.sasl.credentials, name)
            if not credential then
                error('Unknown credential in sasl.automatic: ' .. name, 0)
            end
            table.insert(credentials, credential)
        end
        irc.sasl_credentials = credentials
    end

    -- resolved before anything is sent, since it may prompt
    local ok, password = pcall(secrets.server_password, t, cfg.server)
    if not ok then
        t:log('irc', 'Password resolution failed: %s', password)
        password = nil
    end

    local nick  = cfg.identity.nick
    local user  = cfg.identity.user  or nick
    local gecos = cfg.identity.gecos or nick

    t:send('CAP', 'LS', '302')
    if password then
        t:send('PASS', {content = password, secret = true})
    end
    t:send('NICK', nick)
    irc.nick = nick -- optimistic
    t:send('USER', user, '0', '*', gecos)

    -- "<client> :Welcome to the <networkname> Network, <nick>[!<user>@<host>]"
    local welcome = cap.LS(t) or t:wait_irc {N.RPL_WELCOME}
    irc.nick = welcome[1] -- first confirmation

    -- "<client> :End of /MOTD command."
    -- "<client> :MOTD File is missing"
    t:wait_irc {N.RPL_ENDOFMOTD, N.ERR_NOMOTD}

    t:api 'hub.net.manager'.set_phase(t.net, 'connected')
    rec.registered_at = clock.now()
    t:log('irc', 'registered as %s', irc.nick)
    t:emit('net.registered', {net = t.net, nick = irc.nick})

    -- start waiting for our nickname
    if irc.recover_nick and cfg.reclaim_nick and irc_model.has_monitor(irc) then
        t:send('MONITOR', '+', cfg.identity.nick)
    end

    oper_up(t, cfg)
end
