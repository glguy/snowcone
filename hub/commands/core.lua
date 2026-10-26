-- Commands that don't depend on a network or feature.
--
-- A command body gets a context first, then the arguments its spec parsed.
-- Bodies call runtime, net and feature APIs only, so they also work
-- without a terminal.

local dispatch <const> = require 'hub.runtime.dispatch'
local log      <const> = require 'hub.runtime.log'
local manager  <const> = require 'hub.net.manager'
local send     <const> = require 'hub.net.send'
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
        name = 'quit',
        spec = '',
        help = 'Close every connection and exit',
        fn = function()
            dispatch.route 'app.quit' ()
        end,
    },
}

return M
