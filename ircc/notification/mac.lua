local function esc(str)
    return str:gsub('([\\"])', '\\%1')
end

local M = {}

function M.notify(previous, buffer, nick, msg)
    if not previous then
        local tag = 'irc.snowcone.' .. buffer
        -- weird \< escape due to terminal-notifier quirk
        os.execute(string.format(
            'terminal-notifier -title Snowcone \z
            -subtitle "%s" \z
            -sound default \z
            -message "\\<%s> %s" \z
            -group "%s" \z
            &> /dev/null &',

            esc(buffer),
            esc(nick),
            esc(msg),
            esc(tag)))
        return tag
    else
        return previous
    end
end

function M.dismiss(tag)
    os.execute(string.format(
        'terminal-notifier -remove "%s" &> /dev/null &',
        esc(tag)))
end

return M
