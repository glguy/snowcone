-- Commands that don't depend on a network or feature.
--
-- A command body gets a context first, then the arguments its spec parsed.
-- Bodies call runtime, net and feature APIs only, so they also work
-- without a terminal.

local OrderedMap <const> = require 'hub.lib.OrderedMap'
local dispatch <const> = require 'hub.runtime.dispatch'
local log      <const> = require 'hub.runtime.log'
local manager  <const> = require 'hub.net.manager'
local irc_model <const> = require 'hub.net.irc'
local sasl     <const> = require 'hub.net.sasl'
local secrets  <const> = require 'hub.runtime.secrets'
local send     <const> = require 'hub.net.send'
local task     <const> = require 'hub.runtime.task'
local timer    <const> = require 'hub.runtime.timer'

local M = {}

M.commands = {
    {
        name = 'reload',
        spec = '',
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
        help = 'Run Lua code and show its result',
        fn = function(_, code)
            local chunk, message = load(code, '=(eval)', 't')
            if not chunk then
                log.add('eval', '%s', message)
                return
            end
            local results = table.pack(pcall(chunk))
            if results.n > 1 or not results[1] then
                local parts = {}
                for i = 2, results.n do
                    parts[i - 1] = tostring(results[i])
                end
                log.add('eval', '%s', table.concat(parts, '\t'))
            end
        end,
    },
    {
        name = 'connect',
        spec = '',
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
        scope = 'net',
        help = 'Disconnect the network and stay disconnected; optional QUIT message',
        fn = function(ctx, message)
            manager.disconnect(ctx.net, message ~= '' and message or nil)
        end,
    },
    {
        name = 'reconnect',
        spec = '',
        scope = 'net',
        help = 'Drop the connection and connect again now, with current configuration',
        fn = function(ctx)
            manager.reconnect(ctx.net)
        end,
    },
    {
        name = 'quote',
        spec = '$r',
        scope = 'net',
        help = 'Send an IRC command, checked and shown in the console',
        fn = function(ctx, text)
            local msg = snowcone.parse_irc(text)
            if not msg then error('failed to parse IRC command', 0) end
            if msg.source then error('source not supported', 0) end
            if next(msg.tags) then error('tags not supported', 0) end
            send.send(ctx.net, msg.command, table.unpack(msg))
        end,
    },
    {
        name = 'raw',
        spec = '$r',
        scope = 'net',
        help = 'Send a line exactly as typed',
        fn = function(ctx, text)
            send.raw(ctx.net, text)
        end,
    },
    {
        name = 'nick',
        spec = '$g',
        scope = 'net',
        help = 'Change nickname',
        fn = function(ctx, nick)
            send.send(ctx.net, 'NICK', nick)
        end,
    },
    {
        name = 'sasl',
        spec = '$g',
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
        help = 'Close every connection and exit',
        fn = function()
            dispatch.route 'app.quit' ()
        end,
    },
}

return M
