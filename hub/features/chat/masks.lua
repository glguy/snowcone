-- Channel ban masks (user@host, for *!mask) for Libera.Chat.
-- The cases are tested in tests/hub/test-chat.lua.
--
-- Unlike a K-Line, a channel ban never reveals an address behind a
-- cloak, so it works with the address hidden (255.255.255.255). Gateway
-- cloaks are banned like any other.

return function(username, ipaddress, hostname)

    -- Ignore the paid status of an IRCCloud account (uid or sid)
    if hostname:sub(-13) == '.irccloud.com' then
        return '?' .. username:sub(2) .. '@*.irccloud.com'
    end

    -- Only honor identd
    if username:sub(1, 1) == '~' then
        username = '*'
    end

    -- Don't decloak users or match spoofed IPs
    if hostname:find('/', 1, true) or ipaddress == '255.255.255.255' then
        return '*@' .. hostname
    end

    return username .. '@' .. ipaddress
end
