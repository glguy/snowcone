local Buffer = require 'components.Buffer'
local Task = require 'components.Task'
local challenge = require 'utils.challenge'
local mkcommand = require 'utils.mkcommand'
local sasl = require 'sasl'
local send = require 'utils.send'

local M = {}

local function add_command(name, spec, func)
    M[name] = mkcommand(spec, func)
end

-- quote actually parses the message and integrates it into the
-- console view as a processed message
add_command('quote', '$g$R', function(cmd, str)
    local args = {}
    while true do
        local arg, rest = str:match '^ *([^ :][^ ]*)(.*)$'
        if arg then
            table.insert(args, arg)
            str = rest
        else
            break
        end
    end
    local colon, final = str:match '^ *(:?)(.*)$'
    if colon == ':' or final ~= '' then
        table.insert(args,final)
    end
    send(cmd, table.unpack(args))
end)

-- raw just dumps the text directly into the network stream
add_command('raw', '$r', function(args)
    if conn then
        conn:send(args .. '\r\n')
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

add_command('quit', '$R', quit)

for k, _ in pairs(views) do
    add_command(k, '', function() view = k end)
end

-- Pretending to be an IRC client

add_command('close', '', function()
    if irc_state
    and irc_state:has_monitor()
    and irc_state:is_monitored(talk_target)
    then
        send('MONITOR', '-', talk_target)
        irc_state.monitor[snowcone.irccase(talk_target)] = nil
    end

    if talk_target and view == 'buffer' then
        buffers[talk_target] = nil
        talk_target = next(buffers)
        if not talk_target then
            view = 'console'
        end
    end
end)

add_command('talk', '$g', function(target)
    talk_target = snowcone.irccase(target)
    view = 'buffer'

    if irc_state and irc_state.phase == 'connected' then
        -- join the channel if it's a channel and we're not in it
        if irc_state:is_channel_name(talk_target) then
            if not irc_state.channels[talk_target] then
                send('JOIN', target)
            end
        elseif irc_state:has_monitor() and not irc_state:is_monitored(talk_target) then
            send('MONITOR', '+', talk_target)
        end

        local buffer = buffers[talk_target]
        if not buffer then
            buffer = Buffer(target)
            buffers[talk_target] = buffer
            local maxhistory = buffer.messages.max

            if irc_state:has_chathistory() then
                local amount = irc_state.max_chat_history
                if nil == amount or amount > maxhistory then
                    amount = maxhistory
                end
                send('CHATHISTORY', 'LATEST', target, '*', amount)
            end
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
    if irc_state.phase == 'connected' and conn then
        conn:send('MODE ' .. irc_state.nick .. ' ' .. args .. '\r\n')
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

add_command('challenge', '', function()
    if not configuration.oper_username then
        status('challenge', 'no username configured: `oper_username`')
    elseif not configuration.challenge_key then
        status('challenge', 'no challenge key configured: `challenge_key`')
    else
        Task(challenge)
    end
end)

add_command('oper', '', function()
    if not configuration.oper_username then
        status('oper', 'no username configured: `oper_username`')
    elseif not configuration.oper_password then
        status('oper', 'no password configured: `oper_password`')
    else
        send('OPER', configuration.oper_username,
        {content=configuration.oper_password, secret=true})
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
        Task(sasl, entry)
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
                if true ~= v then
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

return M
