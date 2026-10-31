-- Commands that don't depend on a network or feature.
--
-- A command body gets a context first, then the arguments its spec parsed.
-- Bodies call runtime, net and feature APIs only, so they also work
-- without a terminal.

local OrderedMap <const> = require 'hub.lib.OrderedMap'
local bus      <const> = require 'hub.runtime.bus'
local dispatch <const> = require 'hub.runtime.dispatch'
local log      <const> = require 'hub.runtime.log'
local manager  <const> = require 'hub.net.manager'
local quote    <const> = require 'hub.commands.quote'
local irc_model <const> = require 'hub.net.irc'
local sasl     <const> = require 'hub.net.sasl'
local secrets  <const> = require 'hub.runtime.secrets'
local send     <const> = require 'hub.net.send'
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

M.commands = {
    {
        name = 'reload',
        spec = '',
        group = 'client',
        help = 'Reload code and configuration, keeping connections and state',
        fn = function()
            -- Not from inside the command's own frame: the reload replaces
            -- the code that is running it
            timer.start('commands', 0, 'app.reload')
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
            local rec = HUB.state.nets[ctx.net]
            if rec.phase == 'idle' then
                manager.connect(ctx.net)
            else
                rec.target = 'connected'
            end
        end,
    },
    {
        name = 'disconnect',
        spec = '$R',
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
        fn = function(ctx, text)
            local msg = snowcone.parse_irc(text)
            if not msg then error('failed to parse IRC command', 0) end
            if msg.source then error('source not supported', 0) end
            -- a label typed by hand is left for the user to follow in the
            -- console, as is everything without labeled-response
            local irc = HUB.state.nets[ctx.net].irc
            if msg.tags.label or not (irc and irc_model.has_labels(irc)) then
                send.send_tagged(ctx.net, msg.tags, msg.command, table.unpack(msg))
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
            send.send(ctx.net, 'NICK', nick)
        end,
    },
    {
        name = 'sasl',
        spec = '$g',
        usage = 'credential',
        group = 'connection',
        scope = 'net',
        help = 'Authenticate now with a configured SASL credential',
        fn = function(ctx, name)
            local rec = HUB.state.nets[ctx.net]
            local credential = secrets.get_credential(rec.cfg.sasl and rec.cfg.sasl.credentials, name)
            if not credential then
                error('unknown credential: ' .. name, 0)
            end
            if not (rec.irc and irc_model.has_sasl(rec.irc)) then
                error('SASL is not available', 0)
            end
            task.spawn('sasl', {net = ctx.net, owner = 'commands'}, sasl.authenticate, credential)
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
            local out = assert(io.open(filename, 'w'))
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
