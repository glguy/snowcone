local tablex = require 'pl.tablex'
local lexer = require 'pl.lexer'

local challenge = require 'utils.challenge'
local mkcommand = require 'utils.mkcommand'
local sasl = require 'sasl'
local send = require 'utils.send'
local utils_time = require 'utils.time'

local colormap =
  { black = ncurses.black, red = ncurses.red, green = ncurses.green,
    yellow = ncurses.yellow, blue = ncurses.blue, magenta = ncurses.magenta,
    cyan = ncurses.cyan, white = ncurses.white, }

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

add_command('nettrack', '$g $g', function(name, mask)
    add_network_tracker(name, mask)
end)

add_command('filter', '$R', function(args)
    if args == '' then
        filter = nil
    else
        filter = args
    end
end)

add_command('sync', '', function()
    counter_sync_commands()
end)

add_command('reload', '', function()
    assert(loadfile(arg[0]))()
end)

add_command('eval', '$r', function(args)
    local chunk, message = load(args, '=(eval)', 't')
    if chunk then
        local _, ret = pcall(chunk)
        if ret then
            status('eval', '%s', ret)
        else
            status_message = nil
        end
    else
        status('eval', '%s', message)
    end
end)

add_command('quit', '', quit)

add_command('inject', '$r', function(arg)
    local parse_snote = require 'utils.parse_snote'
    local time = os.date('!%H:%M:%S')
    local server = 'INJECT.'
    local event = parse_snote(time, server, arg)
    if event then
        local handlers = require 'handlers.snotice'
        local handler = handlers[event.name]
        if handler then
            handler(event)
        else
            status('inject', 'no handler')
        end
    else
        status('inject', 'parse failed')
    end
end)

add_command('addwatch', '$r', function(args)
    local watch = {}
    local id
    for kind, token in lexer.scan(args) do

        if kind == 'iden' and token == 'beep' then
            watch.beep = true

        elseif kind == 'iden' and token == 'flash' then
            watch.flash = true

        elseif kind == 'iden' and token == 'nobeep' then
            watch.beep = false

        elseif kind == 'iden' and token == 'noflash' then
            watch.flash = false

        elseif kind == 'iden' and colormap[token] then
            watch.color = colormap[token]

        elseif kind == 'iden' and token == 'filter' then
            watch.mask = filter

        elseif kind == 'string' then
            watch.mask = token

        elseif kind == 'number' and math.tointeger(token) then
            id = math.tointeger(token)

        else
            status('addwatch', 'Unexpected token: %s', token)
            return
        end
    end

    -- New watch
    if id == nil then
        if watch.mask == nil then
            status('addwatch', 'No watch mask specified')
            return
        end

        watch.active = true
        watch.hits = 0

        table.insert(watches, watch)
        status('addwatch', 'Added watch #%d', #watches)

    -- Updating an old watch
    else
        local previous = watches[id]
        if previous then
            tablex.update(previous, watch)
            status('addwatch', 'Updated watch #%d', id)
        else
            status('addwatch', 'So such watch')
        end
    end
end)

add_command('delwatch', '$i', function(i)
    if watches[i] then
        table.remove(watches, i)
    elseif i == nil then
        status('delwatch', 'delwatch requires integer argument')
    else
        status('delwatch', 'delwatch index out of range')
    end
end)

for k, _ in pairs(views) do
    add_command(k, '', function() view = k end)
end

add_command('versions', '', function()
    for server, _ in pairs(links) do
        send('VERSION', server)
    end
    versions = {}
end)

add_command('uptimes', '', function()
    for server, _ in pairs(links) do
        send('STATS', 'u', server)
    end
    uptimes = {}
end)

add_command('duration', '$r', function(arg)
    arg = string.gsub(arg, ' +', '')
    local n = utils_time.parse_duration(arg)
    if n and n > 0 then
        kline_duration = arg
    else
        status('error', 'bad duration: %s', arg)
    end
end)

-- Pretending to be an IRC client

add_command('msg', '$g $r', function(target, message)
    send('PRIVMSG', target, message)
end)

add_command('notice', '$g $r', function(target, message)
    send('NOTICE', target, message)
end)

add_command('umode', '$R', function(args)
    -- raw send_irc hack to allow args to contain spaces
    conn:send('MODE ' .. irc_state.nick .. ' ' .. args .. '\r\n')
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
    if not configuration.oper_username then
        status('challenge', 'no username configured: `oper_username`')
    elseif not configuration.challenge_key then
        status('challenge', 'no challenge key configured: `challenge_key`')
    else
        challenge.start()
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
        sasl.start(entry)
    else
        status('sasl', 'sasl not available')
    end
end)

add_command('kline_nick', '$g', function(nick)
    local entry = users:lookup(nick)
    if entry then
        entry_to_kline(entry)
    else
        irc_state.kline_hunt[snowcone.irccase(nick)] = {}
        send('WHO', nick, '%tuihn,696')
    end
end)

return M
