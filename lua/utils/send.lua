return function(cmd, ...)
    local parts = table.pack(cmd, ...)
    local n = parts.n
    if n > 1 then
        parts[n] = ':' .. parts[n]
    end
    snowcone.send_irc(table.concat(parts, ' ') .. '\r\n')
end
