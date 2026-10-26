-- K-Line masks for Libera.Chat (from dashboard/utils/libera_masks.lua).
-- The cases are tested in tests/hub/test-oper.lua.
--
-- Gateway and NAT cloaks are banned by cloak; everyone else by IP, with
-- the username only when identd vouches for it (or trust_uname is set).

local function compute_kline_mask(username, ipaddress, hostname, trust_uname)

    if hostname:sub(1, 8) == 'gateway/' or hostname:sub(1, 4) == 'nat/' then

        if hostname:sub(-8) == '/session' then
            error('K-line failed: unresolved session', 0)
        end

        -- Cloaked gateway-account bans ignore ident
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
