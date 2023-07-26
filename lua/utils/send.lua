return function(cmd, ...)

    local msg = {
        tags = {},
        command = cmd,
        source = ">>>",
        timestamp = uptime,
        time = os.date("!%H:%M:%S"),
    }

    local parts = {cmd}
    local n = #{...}

    for i, v in ipairs({...}) do
        local part
        if type(v) == 'table' then
            part = tostring(v.content)
            if v.secret then
                msg[i] = '********'
            else
                msg[i] = part
            end
        else
            part = tostring(v)
            msg[i] = part
        end

        if not string.match(part, '^[^ :][^ ]*$') then
            assert(i == n)
            parts[i+1] = ':' .. part
        else
            parts[i+1] = part
        end
    end

    snowcone.send_irc(table.concat(parts, ' ') .. '\r\n')

    messages:insert(true, msg)
end
