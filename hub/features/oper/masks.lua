-- K-Line masks for Libera.Chat.
-- The cases are tested in tests/hub/test-oper.lua.
--
-- Gateway cloaks are banned by cloak; everyone else by IP, with
-- the username only when identd vouches for it (or trust_uname is set).

local function compute_kline_mask(username, ipaddress, hostname, trust_uname)

    -- A gateway cloak (gateway/x/y/account) is banned whole, without ident
    if hostname:sub(1, 8) == 'gateway/' then
        return '*@' .. hostname
    end

    if ipaddress == nil then
        error('K-line failed: Missing IP address', 0)
    end

    -- Either I missed a case or I'm trying to k-line staff
    if ipaddress == '255.255.255.255' then
        error('K-line failed: Spoofed IP address', 0)
    end

    -- These k-lines wouldn't work, anyway.
    if ipaddress == '127.0.0.1' then
        error('K-line failed: Immune', 0)
    end

    -- Only honor identd
    if not trust_uname and username:sub(1, 1) == '~' then
        username = '*'
    end

    return username .. '@' .. ipaddress
end

return compute_kline_mask
