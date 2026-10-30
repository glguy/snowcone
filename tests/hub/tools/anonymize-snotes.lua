-- Turn captured server notices into an anonymized fixture.
--
--   snowcone tests/hub/tools/anonymize-snotes.lua CAPTURE OUT.log
--
-- CAPTURE has one notice per line: <server> TAB <notice text>. It holds
-- personal data and must stay out of the repository. OUT.log gets IRC lines
-- with synthetic server-time tags.
--
-- Every personal field the reference parser extracts (nicks, usernames,
-- hosts, IPs, gecos, accounts, oper names, channels, masks, reasons) is
-- replaced with a synthetic value, consistently across the capture, so a
-- K-Line and the notices about users it rejects still refer to the same
-- mask. IPv4 addresses move into 198.18.0.0/15 and IPv6 into 2001:db8::/32.
-- Server names stay: they are public. Server-generated exit reasons stay.
--
-- A line is kept only if it parses to the same notice with exactly the
-- replaced values; otherwise it is dropped and counted. Finally no original
-- value may appear anywhere in the output.

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local parse = dofile(here .. '/parse_snote.lua')

local capture_name, out_name = arg[1], arg[2]
assert(capture_name and out_name, 'usage: anonymize-snotes.lua CAPTURE OUT.log')

------------------------------------------------------------------------
-- consistent replacement maps

local maps = {}
local counters = {}
local originals = {} -- every replaced value, for the final check

local function mapped(kind, value, make)
    local map = maps[kind]
    if not map then
        map = {}
        maps[kind] = map
    end
    local v = map[value]
    if v == nil then
        local n = (counters[kind] or 0) + 1
        counters[kind] = n
        v = make(n)
        map[value] = v
    end
    originals[value] = true
    return v
end

local function is_wild(s)
    return s:match '^[*?~]*$' ~= nil
end

local function ip(value)
    if value == '0' then return value end
    local addr, bits = value:match '^([^/]+)(/%d+)$'
    addr = addr or value
    if not snowcone.pton(addr) then return nil end
    local new = mapped('ip', addr, function(n)
        if addr:find ':' then
            return string.format('2001:db8::%x', n)
        end
        return string.format('198.18.%d.%d', n // 256, n % 256)
    end)
    return new .. (bits or '')
end

local function nick(value)
    return mapped('nick', value, function(n) return 'nick' .. n end)
end

local function channel(value)
    return mapped('channel', value, function(n) return '#chan' .. n end)
end

local function user(value)
    if is_wild(value) then return value end
    local tilde, rest = value:match '^(~?)(.*)$'
    return tilde .. mapped('user', rest, function(n) return 'user' .. n end)
end

local function host(value)
    if is_wild(value) then return value end
    local as_ip = ip(value)
    if as_ip then return as_ip end
    if value:find '/' then
        local first = value:match '^[^/]*'
        return mapped('cloak', value, function(n) return first .. '/anon' .. n end)
    end
    if value:find '[*?]' then
        return mapped('hostpat', value, function(n) return '*.anon' .. n .. '.example' end)
    end
    return mapped('host', value, function(n) return 'host' .. n .. '.example.net' end)
end

local function mask(value)
    local u, h = value:match '^([^@]*)@(.*)$'
    if u then
        return user(u) .. '@' .. host(h)
    end
    local as_ip = ip(value)
    if as_ip then return as_ip end
    if value:sub(1, 1) == '#' then return channel(value) end
    if is_wild(value) then return value end
    return mapped('mask', value, function(n) return 'mask' .. n end)
end

local function target(value)
    if value:sub(1, 1) == '#' then return channel(value) end
    return nick(value)
end

-- Exit reasons the server writes itself carry nothing personal
local server_reasons = {
    '^Ping timeout: %d+ seconds$',
    '^Read error: [%w %-]+$',
    '^Client Quit$',
    '^Remote host closed the connection$',
    '^K%-Lined$',
    '^D%-Lined$',
    '^Excess Flood$',
    '^Max SendQ exceeded$',
    '^Changing host$',
    '^Connection closed$',
    '^Registration timed out$',
    '^Quit: $',
}

local function reason(value)
    for _, p in ipairs(server_reasons) do
        if value:match(p) then return value end
    end
    return mapped('reason', value, function(n) return 'reason ' .. n end)
end

local field_maps = {
    nick = nick, old = nick, new = nick,
    user = user,
    host = host,
    ip = ip,
    gecos = function(v) return mapped('gecos', v, function(n) return 'Real Name ' .. n end) end,
    account = function(v)
        if is_wild(v) then return v end
        return mapped('account', v, function(n) return 'account' .. n end)
    end,
    oper = function(v) return mapped('oper', v, function(n) return 'oper' .. n end) end,
    mask = mask,
    reason = reason,
    target = target,
    channel = channel,
    from = function(v)
        if v:find '%.' then return v end -- a server
        return nick(v)
    end,
    arg = function(v) return mapped('arg', v, function(n) return 'arg' .. n end) end,
}

-- Which field's replacement wins when several share a value
local field_order <const> = {
    'nick', 'old', 'new', 'oper', 'account', 'user', 'host', 'ip', 'mask',
    'channel', 'target', 'from', 'gecos', 'reason', 'arg',
}

------------------------------------------------------------------------
-- rewriting

local function replace_all(text, old, new)
    local escaped = old:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0')
    local repl = new:gsub('%%', '%%%%')
    return (text:gsub(escaped, repl))
end

-- Notices with personal text in parts the parser doesn't capture. Their
-- fixtures are written by hand instead.
local skip_names <const> = {
    override = true, -- (kind) quotes the overridden command
    badlogin = true, -- the text after the last field isn't parsed
}

local function anonymize(server, body)
    -- the KILL path lists hosts and nicks
    body = body:gsub('^(Received KILL message for .- From %S+) Path: %S+', '%1 Path: services.example')

    local ev = parse(nil, server, body)
    if not ev then return nil, 'unparsed' end
    if skip_names[ev.name] then return nil, 'skipped ' .. ev.name end

    -- Fields with the same value (a nick that is also the account, an oper
    -- nick that is also the oper name) share one replacement: whichever
    -- field comes first in this order decides it.
    local wanted = {}
    local by_value = {}
    for _, field in ipairs(field_order) do
        local v = ev[field]
        if type(v) == 'string' then
            local new = by_value[v]
            if new == nil then
                new = field_maps[field](v)
                if new == nil then return nil, 'unmappable ' .. field end
                by_value[v] = new
            end
            wanted[field] = new
        end
    end

    -- Replace through placeholders, longest first, so a value that contains
    -- another goes whole and no original can match inside a replacement
    local swaps = {}
    for old, new in pairs(by_value) do
        if old ~= new then table.insert(swaps, {old, new}) end
    end
    table.sort(swaps, function(a, b) return #a[1] > #b[1] end)
    for i, s in ipairs(swaps) do
        body = replace_all(body, s[1], '\1' .. i .. '\1')
    end
    body = body:gsub('\1(%d+)\1', function(i) return swaps[tonumber(i)][2] end)

    local check = parse(nil, server, body)
    if not check or check.name ~= ev.name then return nil, 'reparse ' .. ev.name end
    for field, v in pairs(wanted) do
        if check[field] ~= v then return nil, 'field ' .. ev.name .. '.' .. field end
    end
    return body, ev.name
end

------------------------------------------------------------------------

local lines, names, dropped = {}, {}, {}
for line in io.lines(capture_name) do
    local server, text = line:match '^([^\t]+)\t%*%*%* Notice %-%- (.*)$'
    if server then
        local body, why = anonymize(server, text)
        if body then
            names[why] = (names[why] or 0) + 1
            local i = #lines
            local time = string.format('2026-01-01T00:%02d:%02d.%03dZ', i // 300 % 60, i // 5 % 60, i % 5 * 200)
            table.insert(lines, string.format('@time=%s :%s NOTICE * :*** Notice -- %s', time, server, body))
        else
            dropped[why] = (dropped[why] or 0) + 1
        end
    end
end

-- No original value may survive anywhere in the output
local text = table.concat(lines, '\n')
for value in pairs(originals) do
    if #value >= 3 and not is_wild(value) and text:find(value, 1, true) then
        -- a value that is also a public server name or a mapped token is fine
        local public = value:match '%.libera%.chat$'
        if not public then
            error('original value survived: ' .. value)
        end
    end
end

local out = assert(io.open(out_name, 'w'))
out:write(text, '\n')
out:close()

local function report(label, t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        print(string.format('%s %-24s %d', label, k, t[k]))
    end
end
report('kept   ', names)
report('dropped', dropped)
print('lines', #lines)
