local M = {}

local function report(exitcode, stdout, stderr)
    if nil == exitcode then
        status('notify', 'execute error: %s', stdout)
    elseif 0 ~= exitcode then
        status('notify', 'unexpected exit: %d', exitcode)
        if '' ~= stdout then status('notify', 'stdout: %s', stdout) end
        if '' ~= stderr then status('notify', 'stderr: %s', stderr) end
    end
end

function M.notify(previous, buffer, nick, msg)
    if not previous then
        local tag = 'irc.snowcone.' .. buffer
        -- weird \< escape due to terminal-notifier quirk
        snowcone.execute(
            'terminal-notifier',
            {'-title',    'Snowcone',
             '-subtitle', buffer,
             '-sound',    'default',
             '-message',  string.format("\\<%s> %s", nick, msg),
             '-group',    tag},
            report, '')
        return tag
    else
        return previous
    end
end

function M.dismiss(tag)
    snowcone.execute('terminal-notifier', {'-remove', tag}, report, '')
end

return M
