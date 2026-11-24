-- Commands that don't depend on a network or feature.
--
-- A command body gets a context first, then the arguments its spec parsed.
-- Bodies call runtime, net and feature APIs only, so they also work
-- without a terminal.

local OrderedMap <const> = require 'hub.lib.OrderedMap'
local bus      <const> = require 'hub.runtime.bus'
local config   <const> = require 'hub.runtime.config'
local dispatch <const> = require 'hub.runtime.dispatch'
local log      <const> = require 'hub.runtime.log'
local manager  <const> = require 'hub.net.manager'
local oper     <const> = require 'hub.net.oper'
local own_nick <const> = require 'hub.net.nick'
local quote    <const> = require 'hub.commands.quote'
local irc_model <const> = require 'hub.net.irc'
local sasl     <const> = require 'hub.net.sasl'
local send     <const> = require 'hub.net.send'
local spell    <const> = require 'hub.runtime.spell'
local task     <const> = require 'hub.runtime.task'
local timer    <const> = require 'hub.runtime.timer'

local M = {}

-- A value for a one-line summary: a table by its size, a string quoted,
-- anything else as tostring gives it (which a __tostring can break)
local function summarize(v)
    if type(v) == 'table' then
        local n = 0
        for _ in next, v do n = n + 1 end
        return string.format('table (%d %s)', n, n == 1 and 'entry' or 'entries')
    elseif type(v) == 'string' then
        return string.format('%q', #v > 60 and v:sub(1, 60) .. '…' or v)
    end
    local ok, text = pcall(tostring, v)
    return ok and text or '?'
end

-- Tags as IRC reads them: after the @, keys with or without =value,
-- separated by ;
local function good_tags(word)
    for tag in (word:sub(2) .. ';'):gmatch '([^;]*);' do
        if tag:match '^[^=]*' == '' then return false end
    end
    return true
end

-- /quote's line as IRC reads it: tags (a first word starting with @), the
-- command, then its parameters, a word each, until one starting with :
-- takes the rest of the line. Red: tags without a key, a command not of
-- letters and digits, a source (:nick before the command), as /quote
-- sends none, and a NUL anywhere. Still to come, the tags and the command
-- until given, and parameters until there is one.
local function quote_shape(_, rest, slot)
    local words, pos = {}, 1
    local command_at = rest:sub(1, 1) == '@' and 2 or 1
    while true do
        local lo = rest:match('^ *()', pos)
        if lo > #rest then break end
        local hi
        if #words >= command_at and rest:sub(lo, lo) == ':' then
            hi = #rest
        else
            hi = (rest:find(' ', lo, true) or #rest + 1) - 1
        end
        local word = rest:sub(lo, hi)
        local ok, final = true, false
        if word:find('\0', 1, true) then
            ok, final = false, true
        elseif #words + 1 < command_at then
            ok = good_tags(word)
        elseif #words + 1 == command_at then
            final = word:sub(1, 1) == ':'
            ok = not final and word:find '^%w+$' ~= nil
        end
        table.insert(words, {lo = lo, hi = hi, ok = ok, final = final})
        pos = hi + 1
    end
    local tags, command, params = slot[1], slot[2], slot[3]
    local ghosts
    if not words[1] then
        ghosts = {tags, command, params}
    elseif #words < command_at then
        ghosts = {command, params}
    elseif #words == command_at then
        ghosts = {params}
    end
    return {words = words, ghosts = ghosts or {}}
end

M.commands = {
    {
        name = 'reload',
        spec = '$R',
        usage = '[file]',
        group = 'client',
        help = 'Reload code and configuration, keeping connections and state; a file is read from then on',
        fn = function(_, file)
            file = file:match '^%s*(.-)%s*$'
            file = file ~= '' and config.user_path(file) or nil
            -- Not from inside the command's own frame: the reload replaces
            -- the code that is running it
            timer.start('commands', 0, 'app.reload', file)
        end,
    },
    {
        name = 'eval',
        spec = '$r',
        usage = 'code',
        group = 'client',
        help = 'Run Lua code and show its values in the detail pane',
        fn = function(_, code)
            local chunk, message = load(code, '=(eval)', 't')
            if not chunk then
                log.add('eval', '%s', message)
                return
            end
            local results = table.pack(pcall(chunk))
            if not results[1] then
                log.add('eval', '%s', tostring(results[2]))
                return
            end
            if results.n == 1 then return end

            -- the values themselves, live, for the UI to show in full
            local value = {code = code, n = results.n - 1, table.unpack(results, 2, results.n)}
            local parts = {}
            for i = 1, value.n do
                parts[i] = summarize(value[i])
            end
            log.add_detail(nil, 'eval', {kind = 'value', data = value}, '%s', table.concat(parts, ', '))
            bus.emit('eval.result', {value = value})
        end,
    },
    {
        name = 'connect',
        spec = '',
        group = 'connection',
        scope = 'net',
        help = 'Connect the network, and keep it connected',
        fn = function(ctx)
            manager.connect(ctx.net)
        end,
    },
    {
        name = 'disconnect',
        spec = '$T',
        usage = '[message]',
        group = 'connection',
        scope = 'net',
        help = 'Disconnect the network and stay disconnected; optional QUIT message',
        fn = function(ctx, message)
            manager.disconnect(ctx.net, message ~= '' and message or nil)
        end,
    },
    {
        name = 'reconnect',
        spec = '',
        group = 'connection',
        scope = 'net',
        help = 'Drop the connection and connect again now, with current configuration',
        fn = function(ctx)
            manager.reconnect(ctx.net)
        end,
    },
    {
        name = 'quote',
        spec = '$r',
        usage = '[@tags] command [arguments]',
        group = 'connection',
        scope = 'net',
        help = 'Send an IRC command, checked; its labeled reply shows in the detail pane',
        shape = quote_shape,
        fn = function(ctx, text)
            if text:find('\0', 1, true) then error('a NUL byte cannot be sent', 0) end
            local msg = snowcone.parse_irc(text)
            if not msg then error('failed to parse IRC command', 0) end
            if msg.source then error('source not supported', 0) end
            -- a label typed by hand is left for the user to follow in the
            -- console, as is everything without labeled-response
            local irc = HUB.state.nets[ctx.net].irc
            if msg.tags.label or not (irc and irc_model.has_labels(irc)) then
                send.send_tagged(ctx.net, msg.tags, msg.command, table.unpack((quote.arguments(msg))))
                return
            end
            quote.labeled(ctx.net, msg)
        end,
    },
    {
        name = 'raw',
        spec = '$r',
        usage = 'line',
        group = 'connection',
        scope = 'net',
        help = 'Send a line exactly as typed',
        fn = function(ctx, text)
            send.raw(ctx.net, text)
        end,
    },
    {
        name = 'nick',
        spec = '$g',
        usage = 'nick',
        group = 'connection',
        scope = 'net',
        help = 'Change nickname',
        fn = function(ctx, nick)
            own_nick.declare(ctx.net, nick)
        end,
    },
    {
        name = 'umode',
        spec = '$r',
        usage = 'modes',
        group = 'connection',
        scope = 'net',
        help = 'Change our user modes, e.g. +i-w',
        fn = function(ctx, args)
            local irc = HUB.state.nets[ctx.net].irc
            if not irc then error('not connected', 0) end
            local parts = {}
            for word in args:gmatch '[^ ]+' do table.insert(parts, word) end
            send.send(ctx.net, 'MODE', irc.nick, table.unpack(parts))
        end,
    },
    {
        name = 'oper',
        spec = '$R',
        usage = '[credential]',
        group = 'connection',
        scope = 'net',
        help = 'Become an operator with a configured credential; without one, the automatic ones',
        fn = function(ctx, name)
            name = name:match '^%s*(.-)%s*$'
            local credentials = config.pick_credentials(HUB.state.nets[ctx.net].cfg.oper, name)
            task.spawn('oper', {net = ctx.net, owner = 'commands'}, oper.first, credentials)
        end,
        -- the network's credentials, by name
        complete = function(ctx, before, seed)
            if before ~= '' then return nil end
            local oper_cfg = HUB.state.nets[ctx.net].cfg.oper
            local t = {}
            for _, credential in ipairs(oper_cfg and oper_cfg.credentials or {}) do
                local name = credential.name or credential.mechanism
                if name:sub(1, #seed) == seed then table.insert(t, name) end
            end
            return t
        end,
    },
    {
        name = 'sasl',
        spec = '$R',
        usage = '[credential]',
        group = 'connection',
        scope = 'net',
        help = 'Authenticate now with a configured SASL credential; without one, the automatic ones',
        fn = function(ctx, name)
            local rec = HUB.state.nets[ctx.net]
            name = name:match '^%s*(.-)%s*$'
            local credentials = config.pick_credentials(rec.cfg.sasl, name)
            if not (rec.irc and irc_model.has_sasl(rec.irc)) then
                error('SASL is not available', 0)
            end
            local opts <const> = {net = ctx.net, owner = 'commands'}
            if name ~= '' then
                task.spawn('sasl', opts, sasl.authenticate, credentials[1])
            else
                task.spawn('sasl', opts, sasl.first, credentials)
            end
        end,
        -- the network's credentials, by name
        complete = function(ctx, before, seed)
            if before ~= '' then return nil end
            local sasl_cfg = HUB.state.nets[ctx.net].cfg.sasl
            local t = {}
            for _, credential in ipairs(sasl_cfg and sasl_cfg.credentials or {}) do
                local name = credential.name or credential.mechanism
                if name:sub(1, #seed) == seed then table.insert(t, name) end
            end
            return t
        end,
    },
    {
        name = 'dump',
        spec = '$r',
        usage = 'file',
        group = 'connection',
        scope = 'net',
        help = "Write the network's console to a file, as client and server lines",
        fn = function(ctx, filename)
            local out, err = io.open(config.user_path(filename), 'w')
            if not out then error(err, 0) end
            for msg in OrderedMap.reveach(HUB.state.nets[ctx.net].console) do
                out:write(msg.source == '>>>' and 'C: ' or 'S: ')
                if next(msg.tags) then
                    local sep = '@'
                    for k, v in pairs(msg.tags) do
                        out:write(sep, k)
                        if v ~= '' and v ~= true then
                            out:write('=', (v:gsub('[;\n\r\\ ]', {
                                ['\\'] = '\\\\', [' '] = '\\s', [';'] = '\\:',
                                ['\n'] = '\\n', ['\r'] = '\\r',
                            })))
                        end
                        sep = ';'
                    end
                    out:write ' '
                end
                if msg.source and msg.source ~= '>>>' then
                    out:write(':', msg.source, ' ')
                end
                if type(msg.command) == 'number' then
                    out:write(string.format('%03d', msg.command))
                else
                    out:write(msg.command)
                end
                local n = #msg
                for i, p in ipairs(msg) do
                    out:write(i == n and ' :' or ' ', p)
                end
                out:write '\n'
            end
            out:close()
        end,
    },
    {
        name = 'spell',
        spec = '$g',
        usage = 'word',
        group = 'client',
        help = 'Check the spelling of a word',
        fn = function(_, word)
            if not spell.available() then
                error(spell.unavailable_reason(), 0)
            end
            if not spell.checkable(word) then
                log.add('spell', "%s can't be checked with this dictionary", word)
            elseif spell.check(word) then
                log.add('spell', '%s is spelled correctly', word)
            else
                local t = spell.suggest(word)
                log.add('spell', '%s: %s', word, t[1] and table.concat(t, ', ') or 'no suggestions')
            end
        end,
    },
    {
        name = 'spell_add',
        spec = '$g',
        usage = 'word',
        group = 'client',
        help = 'Add a word to your personal word list',
        fn = function(_, word)
            if not spell.available() then
                error(spell.unavailable_reason(), 0)
            end
            local ok, err = spell.add(word)
            if not ok then error(tostring(err), 0) end
            log.add('spell', 'added %s to %s', word, spell.personal_path())
        end,
    },
    {
        name = 'quit',
        spec = '',
        group = 'client',
        help = 'Close every connection and exit',
        fn = function()
            dispatch.route 'app.quit' ()
        end,
    },
}

return M
