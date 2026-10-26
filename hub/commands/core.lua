-- Commands that don't depend on a network or feature.
--
-- A command body gets a context first, then the arguments its spec parsed.
-- Bodies call runtime, net and feature APIs only, so they also work
-- without a terminal.

local dispatch <const> = require 'hub.runtime.dispatch'
local log      <const> = require 'hub.runtime.log'
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
        name = 'quit',
        spec = '',
        help = 'Close every connection and exit',
        fn = function()
            dispatch.route 'app.quit' ()
        end,
    },
}

return M
