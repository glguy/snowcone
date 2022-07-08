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
        if type(v) == 'table' then
            local txt = tostring(v.content)
            parts[i+1] = txt
            if v.secret then
                msg[i] = '********'
            else
                msg[i] = txt
            end
        else
            v = tostring(v)
            msg[i] = v
            parts[i+1] = v
        end
    end

    local n = #parts
    if n > 1 then
        parts[n] = ':' .. parts[n]
    end
    snowcone.send_irc(table.concat(parts, ' ') .. '\r\n')

    messages:insert(true, msg)
end
