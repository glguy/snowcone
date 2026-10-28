-- Counting connected users per address range, as records.
--
-- A net tracker is a named group of ranges. Each range keeps a count,
-- set from TESTMASK replies and moved by connect and exit notices.
-- Addresses are compared in binary form from snowcone.pton; the binary
-- prefix is stored hex-encoded so state stays printable.

local M = {}

local function hex(s)
    return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

local function unhex(s)
    return (s:gsub('..', function(h) return string.char(tonumber(h, 16)) end))
end

--- A range, from 'address' or 'address/prefix'.
---@return table range {label, network, addrlen, tailix, tailmask, tailbyte, count}
function M.new_range(label)
    local address, prefix = label:match '^([^/]*)/(%d+)$'
    local b
    if address then
        b = snowcone.pton(address)
        prefix = math.tointeger(prefix)
    else
        b = snowcone.pton(label)
        prefix = b and 8 * #b
    end
    if not b then
        error('bad address range: ' .. label, 0)
    end
    if prefix > 8 * #b then
        error('prefix too long: ' .. label, 0)
    end

    local bytes = prefix // 8
    local range = {
        label = label,
        addrlen = #b,
        network = hex(b:sub(1, bytes)),
        count = 0,
    }
    local bits = prefix % 8
    if bits > 0 then
        local mask = 0x100 - (0x100 >> bits)
        range.tailmask = mask
        range.tailbyte = b:byte(bytes + 1) & mask
        range.tailix = bytes + 1
    end
    return range
end

--- A binary address is in the range.
function M.match(range, address)
    local network = unhex(range.network)
    return range.addrlen == #address
       and address:sub(1, #network) == network
       and (not range.tailbyte
            or (address:byte(range.tailix) & range.tailmask) == range.tailbyte)
end

--- Add a range to the named tracker, creating it.
function M.add(net_trackers, name, label)
    local tracker = net_trackers[name]
    if not tracker then
        tracker = {}
        net_trackers[name] = tracker
    end
    tracker[label] = M.new_range(label)
end

--- Set a range's count wherever it is tracked (from TESTMASK).
function M.set(net_trackers, label, count)
    for _, tracker in pairs(net_trackers) do
        local range = tracker[label]
        if range then
            range.count = count
        end
    end
end

--- Move the count of the first matching range of each tracker.
function M.count_ip(net_trackers, ip, delta)
    if next(net_trackers) == nil then return end
    local address = snowcone.pton(ip)
    if not address then return end
    for _, tracker in pairs(net_trackers) do
        for _, range in pairs(tracker) do
            if M.match(range, address) then
                range.count = range.count + delta
                break
            end
        end
    end
end

--- Total count of a tracker.
function M.total(tracker)
    local n = 0
    for _, range in pairs(tracker) do
        n = n + range.count
    end
    return n
end

return M
