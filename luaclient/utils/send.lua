return function(cmd, ...)

    if not send_irc then
        error 'irc not connected'
    end

    local msg = {
        tags = {},
        command = cmd,
        source = ">>>",
        timestamp = uptime,
        time = os.date("!%H:%M:%S"),
    }

    local parts = {cmd}
    local args = {...}
    local n = #args

    for i, v in ipairs(args) do
        local part
        if type(v) == 'table' then
            part = tostring(v.content)
            if v.secret then
                msg[i] = '\x0304*'
            else
                msg[i] = part
            end
        else
            part = tostring(v)
            msg[i] = part
        end

        -- Only the last message can be:
        -- * empty
        -- * leading :
        -- * any space
        if string.find(part, '[\x00\r\n]') then
            error('prohibited character in command argument')
        elseif not string.find(part, '^[^ :][^ ]*$') then
            assert(i == n, 'malformed internal command argument')
            parts[i+1] = ':' .. part
        else
            parts[i+1] = part
        end
    end

    send_irc(table.concat(parts, ' ') .. '\r\n')

    messages:insert(true, msg)

    if cmd == 'PRIVMSG' or cmd == 'NOTICE' then
        local buffer = buffers[snowcone.irccase(msg[1])]
        if buffer then
            buffer:insert(true, msg)
        end
    end
end
