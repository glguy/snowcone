return function(cmd, ...)

    local msg = {
        tags = {},
        command = cmd,
        source = ">>>",
        timestamp = uptime,
        time = os.date("!%H:%M:%S"),
    }

    local parts = {cmd}

    for i, v in ipairs({...}) do
        if type(v) == 'string' then
            msg[i] = v
            parts[i+1] = v
        else
            parts[i+1] = v.content
            if v.secret then
                msg[i] = '********'
            else
                msg[i] = v.content
            end
        end
    end

    local n = #parts
    if n > 1 then
        parts[n] = ':' .. parts[n]
    end
    snowcone.send_irc(table.concat(parts, ' ') .. '\r\n')

    messages:insert(true, msg)
end
