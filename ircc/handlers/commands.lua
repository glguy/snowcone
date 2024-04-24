local Buffer              <const> = require 'components.Buffer'
local Task                <const> = require 'components.Task'
local challenge           <const> = require 'utils.challenge'
local mkcommand           <const> = require 'utils.mkcommand'
local sasl                <const> = require 'sasl'
local send                <const> = require 'utils.send'
local configuration_tools <const> = require 'utils.configuration_tools'
local file                <const> = require 'pl.file'

local M = {}

local function add_command(name, spec, func)
    M[name] = mkcommand(spec, func)
end

-- quote actually parses the message and integrates it into the
-- console view as a processed message
add_command('quote', '$r', function(txt)
    local irc = assert(snowcone.parse_irc(txt), 'failed to parse IRC command')
    assert(irc.source == nil, 'source not supported')
    assert(next(irc.tags) == nil, 'tags not supported')
    send(irc.command, table.unpack(irc))
end)

-- raw just dumps the text directly into the network stream
add_command('raw', '$r', function(args)
    if irc_state then
        irc_state:rawsend(args .. '\r\n')
    else
        status('quote', 'not connected')
    end
end)

add_command('filter', '$R', function(args)
    if args == '' then
        filter = nil
    else
        filter = args
    end
end)

add_command('reload', '', function()
    assert(loadfile(arg[0]))()
end)

add_command('eval', '$r', function(args)
    local chunk, message = load(args, '=(eval)', 't')
    if chunk then
        local _, ret = pcall(chunk)
        if ret ~= nil then
            status('eval', '%s', ret)
        else
            status_message = nil
        end
    else
        status('eval', '%s', message)
    end
end)

add_command('quit', '', quit)

add_command('connect', '', function()
    mode_target = 'connected'
    if mode_current == 'idle' then
        connect()
    end
end)

add_command('disconnect', '', function()
    mode_target = 'idle'
    if mode_current == 'connected' then
        disconnect()
    end
end)

for k, _ in pairs(views) do
    add_command(k, '', function() set_view(k) end)
end

-- Pretending to be an IRC client

add_command('close', '', function()
    if irc_state
    and irc_state:has_monitor()
    and irc_state:is_monitored(talk_target)
    then
        send('MONITOR', '-', talk_target)
        irc_state:del_monitor(talk_target)
    end

    if talk_target and view == 'buffer' then
        buffers[talk_target] = nil
        set_talk_target(next(buffers))
        if not talk_target then
            set_view 'console'
        end
    end
end)

add_command('talk', '$g', function(target)
    set_talk_target(snowcone.irccase(target))
    set_view 'buffer'

    if irc_state and irc_state.phase == 'connected' then

        -- prepare the buffer first so that the chathistory command goes out
        -- before the join command
        local buffer = buffers[talk_target]
        if not buffer then
            buffer = Buffer(target)
            buffers[talk_target] = buffer

            if irc_state:has_chathistory() then
                local maxhistory = buffer.messages.max
                local amount = irc_state.max_chat_history
                if nil == amount or amount > maxhistory then
                    amount = maxhistory
                end
                send('CHATHISTORY', 'LATEST', target, '*', amount)
            end
        end

        -- join the channel if it's a channel and we're not in it
        if irc_state:is_channel_name(talk_target) then
            if not irc_state.channels[talk_target] then
                send('JOIN', target)
            end
        elseif irc_state:has_monitor() and not irc_state:is_monitored(talk_target) then
            send('MONITOR', '+', talk_target)
        end
    end
end)

add_command('msg', '$g $r', function(target, message)
    send('PRIVMSG', target, message)
end)

add_command('ctcp', '$g $r', function(target, message)
    send('PRIVMSG', target, '\x01' .. message .. '\x01')
end)

add_command('notice', '$g $r', function(target, message)
    send('NOTICE', target, message)
end)

add_command('umode', '$R', function(args)
    -- raw hack to allow args to contain spaces
    if irc_state and irc_state.phase == 'connected' then
        irc_state:rawsend('MODE ' .. irc_state.nick .. ' ' .. args .. '\r\n')
    else
        status('umode', 'not connected')
    end
end)

add_command('whois', '$g', function(nick)
    send('WHOIS', nick)
end)

add_command('wii', '$g', function(nick)
    send('WHOIS', nick, nick)
end)

add_command('masktrace', '$g', function(mask)
    send('MASKTRACE', mask)
end)

add_command('testline', '$g', function(mask)
    send('TESTLINE', mask)
end)

add_command('whowas', '$g', function(nick)
    send('WHOWAS', nick)
end)

add_command('nick', '$g', function(nick)
    send('NICK', nick)
end)

add_command('list', '$R', function(arg)
    local channel_list_task = require 'utils.channel_list'
    if arg == '' then
        channel_list_task()
    else
        channel_list_task(arg)
    end
end)

add_command('challenge', '', function()
    if not configuration.oper_username then
        status('challenge', 'no username configured: `oper_username`')
    elseif not configuration.challenge_key then
        status('challenge', 'no challenge key configured: `challenge_key`')
    else
        Task('challenge', irc_state.tasks, challenge)
    end
end)

add_command('oper', '', function()
    if not configuration.oper_username then
        status('oper', 'no username configured: `oper_username`')
    elseif not configuration.oper_password then
        status('oper', 'no password configured: `oper_password`')
    else
        coroutine.wrap(function() -- resolve_password can yield
            local password <const> = configuration_tools.resolve_password(configuration.oper_password)
            send('OPER', configuration.oper_username, {content=password, secret=true})
        end)()
    end
end)

add_command('sasl', '$g', function(name)
    local credentials = configuration.sasl_credentials

    if not credentials then
        status('sasl', 'no sasl credentials configured')
        return
    end

    local entry = credentials[name]
    if not entry then
        status('sasl', 'unknown credentials')
    elseif irc_state:has_sasl() then
        Task('sasl', irc_state.tasks, sasl, entry)
    else
        status('sasl', 'sasl not available')
    end
end)

add_command('dump', '$r', function(path)

    local function escapeval(val)
        return (val:gsub('[;\n\r\\ ]', {
                ['\\'] = '\\',
                [' '] = '\\s',
                [';'] = '\\:',
                ['\n'] = '\\n',
                ['\r'] = '\\r',
            }))
    end

    local log = io.open(path, 'w')
    for irc in messages:reveach() do
        if irc.source == '>>>' then
            log:write('C: ')
        else
            log:write('S: ')
        end
        if next(irc.tags) then
            local sep = '@'
            for k,v in pairs(irc.tags) do
                log:write(sep, k)
                if '' ~= v then
                    log:write('=', escapeval(v))
                end
                sep = ';'
            end
            log:write(' ')
        end
        if irc.source and irc.source ~= '>>>' then
            log:write(':', irc.source, ' ')
        end
        if type(irc.command) == 'number' then
            log:write(string.format('%03d', irc.command))
        else
            log:write(irc.command)
        end
        local n = #irc
        for i, p in ipairs(irc) do
            if i == n then
                log:write(' :', p)
            else
                log:write(' ', p)
            end
        end
        log:write('\n')
    end
    log:close()
end)

add_command('upload_filterdb', '$r', function(path)
    local send_db = require 'utils.hsfilter'
    local pretty = require 'pl.pretty'

    local txt = assert(file.read(path))
    local db = assert(pretty.read(txt))


    local exprs = {}
    local ids = {}
    local flags = {}

    local next_id = 0

    for i, entry in ipairs(db.patterns) do
        local id = next_id
        next_id = next_id + 8
        for _, action in ipairs(entry.actions) do
            id = id + assert(hsfilter.actions[action], 'bad action: ' .. action)
        end

        local flag_val = 0
        for _, flag in ipairs(entry.flags) do
            flag_val = flag_val + assert(hsfilter.flags[flag], 'bad flag: ' .. flag)
        end

        ids[i] = id
        flags[i] = flag_val
        exprs[i] = assert(entry.regexp, 'missing regexp at index ' .. i)
    end

    local platform
    if db.platform then
        platform = {}
        if db.platform.cpu_features then
            platform.cpu_features =
                assert(
                    hsfilter.cpu_features[db.platform.cpu_features],
                    'bad cpu_features: ' .. db.platform.cpu_features)
        end
        if db.platform.tune then
            platform.tune = assert(hsfilter.tune[db.platform.tune], 'bad tune: ' .. db.platform.tune)
        end
    end

    send_db(exprs, flags, ids, platform)

end)

local function pub64(k)
    return snowcone.to_base64(k:export().pub)
end

-- /ecdsa_new <filename.pem>
-- Generate a new ECDSA private key and NickServ SET PUBKEY command
add_command('ecdsa_new', '$g', function(filename)
    local k = myopenssl.gen_pkey('EC', 'P-256')
    k:set_param('point-format', 'compressed')
    file.write(filename, k:to_private_pem())
    print('/msg NickServ SET PUBKEY ' .. pub64(k))
end)

-- /ecdsa_fp <filename.pem>
-- Generate NickServ SET PUBKEY command
add_command('ecdsa_fp', '$g', function(filename)
    local pem = assert(file.read(filename))
    local k = myopenssl.read_pem(pem, true)
    print('/msg NickServ SET PUBKEY ' .. pub64(k))
end)

-- /x25519_new
-- Generate a new X25519 private key and NickServ SET X25519-PUBKEY command
add_command('x25519_new', '', function()
    local k = myopenssl.gen_pkey('X25519')
    print('Private key: ' .. snowcone.to_base64(k:get_raw_private()))
    print('/msg NickServ SET X25519-PUBKEY ' .. pub64(k))
end)

add_command('cert_new', '$g', function(filename)
    local pkey   <close> = myopenssl.gen_pkey 'ED25519'
    local x509   <close> = myopenssl.new_x509()
    local sha512 <close> = myopenssl.get_digest 'sha512'

    -- Populate certificate
    x509:set_version     (2)
    x509:set_serialNumber(1)
    x509:set_issuerName  {CN='snowcone'}
    x509:set_subjectName {CN='snowcone'}
    x509:set_notBefore   '19700101000000Z'
    x509:set_notAfter    '20700101000000Z'
    x509:set_pubkey      (pkey)

    -- Finish certificate
    x509:sign(pkey)

    -- Save certificate and private key together
    file.write(filename, x509:export() .. pkey:to_private_pem())

    -- Compute fingerprint for NickServ
    local raw_fp = x509:fingerprint(sha512)
    local fp = {}
    for i = 1, #raw_fp do
        fp[i] = string.format('%02X', raw_fp:byte(i))
    end
    print('/msg NickServ CERT ADD ' .. table.concat(fp))
end)

return M
