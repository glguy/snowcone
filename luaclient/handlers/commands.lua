local challenge = require 'utils.challenge'
local mkcommand = require 'utils.mkcommand'
local sasl = require 'sasl'
local send = require 'utils.send'
local OrderedMap = require_ 'components.OrderedMap'

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
    if send_irc then
        send_irc(args .. '\r\n')
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
    if talk_target and view == 'buffer' then
        local buffer_name = snowcone.irccase(talk_target)
        buffers[buffer_name] = nil
        view = 'console'
        talk_target = nil
    end
end)

add_command('talk', '$g', function(target)
    talk_target = target
    view = 'buffer'

    local buffer_name = snowcone.irccase(target)

    -- join the channel if it's a channel and we're not in it
    if irc_state:is_channel_name(buffer_name) and not irc_state.channels[buffer_name] then
        send('JOIN', target)
    end

    if not buffers[buffer_name] then
        local maxhistory = 1000
        buffers[buffer_name] = OrderedMap(maxhistory)
        if irc_state:has_chathistory() then
            local amount = tonumber(irc_state.isupport.CHATHISTORY)
            if nil == amount or amount > maxhistory then
                amount = maxhistory
            end
            send('CHATHISTORY', 'LATEST', target, '*', amount)
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
    -- raw send_irc hack to allow args to contain spaces
    if irc_state.phase == 'connected' and send_irc then
        send_irc('MODE ' .. irc_state.nick .. ' ' .. args .. '\r\n')
    else
        status('umode', 'not connected')
    end
end)

add_command('whois', '$g', function(nick)
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
    if not configuration.irc_oper_username then
        status('challenge', 'no username configured: `irc_oper_username`')
    elseif not configuration.irc_challenge_key then
        status('challenge', 'no challenge key configured: `irc_challenge_key`')
    else
        challenge.start()
    end
end)

add_command('oper', '', function()
    if not configuration.irc_oper_username then
        status('oper', 'no username configured: `irc_oper_username`')
    elseif not configuration.irc_oper_password then
        status('oper', 'no password configured: `irc_oper_password`')
    else
        send('OPER', configuration.irc_oper_username,
        {content=configuration.irc_oper_password, secret=true})
    end
end)

add_command('sasl', '', function()
    sasl.start()
end)

return M
