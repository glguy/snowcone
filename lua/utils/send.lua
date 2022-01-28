return function(cmd, ...)
    local parts = {cmd, ...}

    local n = #parts
    if n > 1 then
        parts[n] = ':' .. parts[n]
    end

    snowcone.send_irc(table.concat(parts, ' ') .. '\r\n')
end
