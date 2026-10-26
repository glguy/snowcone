-- macOS notifications through terminal-notifier (from
-- ircc/notification/mac.lua). The program runs in a task, since only the
-- runtime may start processes.

local task <const> = require 'hub.runtime.task'

local M = {}

local function run(args)
    task.spawn('terminal-notifier', {owner = 'notify'}, function(t)
        local code, stdout, stderr = t:execute('terminal-notifier', args, '')
        if code == nil then
            t:log('notify', 'execute error: %s', stdout)
        elseif code ~= 0 then
            t:log('notify', 'unexpected exit: %d %s %s', code, stdout or '', stderr or '')
        end
    end)
end

function M.notify(previous, buffer, nick, msg)
    if previous then return previous end
    local tag = 'irc.snowcone.' .. buffer
    run {
        '-title', 'Snowcone',
        '-subtitle', buffer,
        '-sound', 'default',
        -- \< for a terminal-notifier quirk
        '-message', string.format('\\<%s> %s', nick, msg),
        '-group', tag,
    }
    return tag
end

function M.dismiss(tag)
    run {'-remove', tag}
end

return M
