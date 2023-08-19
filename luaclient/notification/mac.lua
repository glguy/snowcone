local function esc(str)
    return str:gsub('([\\"])', '\\%1')
end

return function(buffer, nick, msg)
    -- weird \< escape due to terminal-notifier quirk
    os.execute(string.format(
        'terminal-notifier -title Snowcone -subtitle "%s" -sound default -message "\\<%s> %s"',
        esc(buffer),
        esc(nick),
        esc(msg)))
end