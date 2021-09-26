local strict = require 'pl.strict'

local M = strict.module 'freenode_masks'

function M.compute_kline_mask(username, ipaddress, hostname)

    if hostname:startswith {'gateway/', 'nat/'} then

        if hostname:endswith '/session' then
            error('K-line failed: unresolved session', 0)
        end

        -- Cloaked gateway-account bans ignore ident
        return '*@' .. hostname
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
    if username:startswith '~' then
        username = '*'
    end

    return username .. '@' .. ipaddress
end

-- Always run the unit tests to ensure I don't change something and start banning the wrong people
assert(
    '*@10.0.0.1' ==
    M.compute_kline_mask('~0a000001', '10.0.0.1', '10.0.0.1'),
    'simple test')
assert(
    '*@gateway/something/somethingelse' ==
    M.compute_kline_mask('user', '255.255.255.255', 'gateway/something/somethingelse'),
    'account gateway')
assert(
    'user@10.0.0.1' ==
    M.compute_kline_mask('user', '10.0.0.1', 'localhost.localdomain'),
    'no cloak with rDNS')
assert(
    'user@10.0.0.1' ==
    M.compute_kline_mask('user', '10.0.0.1', '10.0.0.1'),
    'no cloak no rDNS')
assert(
    '*@10.0.0.1' ==
    M.compute_kline_mask('~user', '10.0.0.1', 'localhost.localdomain'),
    'no cloak with rDNS no identd')
assert(
    '*@10.0.0.1' ==
    M.compute_kline_mask('~user', '10.0.0.1', 'unaffiliated/spammer'),
    'cloak with no identd')
assert(
    not pcall(M.compute_kline_mask, 'user', '127.0.0.1', 'freenode/bot/target'),
    'localhost should fail')
assert(
    not pcall(M.compute_kline_mask, 'user', '255.255.255.255', 'gateway/web/stuff/session'),
    'no raw session ban')
assert(
    '*@2001:470:7857:c::6667' ==
    M.compute_kline_mask('~user', '2001:470:7857:c::6667', '2001:470:7857:c::6667'),
    'ipv6 no rDNS'
)
assert(
    '*@gateway/vpn/provider/user' ==
    M.compute_kline_mask('~user', '1.2.3.4', 'gateway/vpn/provider/user'),
    'normal VPN account'
)
assert(
    '*@gateway/vpn/provider/user/x-11111111' ==
    M.compute_kline_mask('~user', '1.2.3.4', 'gateway/vpn/provider/user/x-11111111'),
    'VPN account with x- suffix'
)
assert(
    '*@gateway/tor-sasl/user/x-12345' ==
    M.compute_kline_mask('~user', '255.255.255.255', 'gateway/tor-sasl/user/x-12345'),
    'Tor gateway'
)

return M