-- hub's library modules on their own.
--
-- Run with:  snowcone tests/hub/test-lib.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')

local function ordered_map(max)
    T.boot {}
    local OrderedMap = T.require 'hub.lib.OrderedMap'
    return OrderedMap, OrderedMap.new(max)
end

local function collect(iter)
    local t = {}
    for v in iter do table.insert(t, v) end
    return t
end

T.case('OrderedMap numbers entries and drops the oldest', function()
    local OrderedMap, om = ordered_map(3)
    T.eq({OrderedMap.first(om), OrderedMap.last(om), OrderedMap.size(om)}, {1, 0, 0}, 'empty')
    T.eq(OrderedMap.get_oldest(om), nil, 'no oldest')
    for _, v in ipairs {'a', 'b', 'c', 'd', 'e'} do OrderedMap.insert(om, v, v) end
    T.eq({OrderedMap.first(om), OrderedMap.last(om), OrderedMap.size(om)}, {3, 5, 3}, 'holds 3 to 5')
    T.eq({OrderedMap.get(om, 2), OrderedMap.get(om, 3), OrderedMap.get(om, 6)}, {nil, 'c', nil}, 'by number')
    T.eq(OrderedMap.get_oldest(om), 'c', 'oldest')
    T.eq(collect(OrderedMap.each(om)), {'e', 'd', 'c'}, 'newest first')
    T.eq(collect(OrderedMap.each(om, 1)), {'d', 'c'}, 'skipping the newest')
    T.eq(collect(OrderedMap.reveach(om)), {'c', 'd', 'e'}, 'oldest first')
    T.eq({OrderedMap.lookup(om, 'b'), OrderedMap.lookup(om, 'c')}, {nil, 'c'}, 'dropped keys forgotten')
    T.eq({OrderedMap.number(om, 'b'), OrderedMap.number(om, 'c'), OrderedMap.number(om, 'e')}, {nil, 3, 5},
        'numbers by key')
    for _, v in ipairs {'f', 'g'} do OrderedMap.insert(om, v, v) end
    T.eq({OrderedMap.number(om, 'e'), OrderedMap.number(om, 'g')}, {5, 7}, 'across the wrap')
end)

T.case('OrderedMap pops the newest, even after wrapping', function()
    local OrderedMap, om = ordered_map(3)
    for _, v in ipairs {'a', 'b', 'c', 'd'} do OrderedMap.insert(om, v, v) end
    T.eq({OrderedMap.pop(om)}, {'d', 'd'}, 'val and key')
    T.eq(OrderedMap.lookup(om, 'd'), nil, 'key forgotten')
    T.eq({OrderedMap.first(om), OrderedMap.last(om), OrderedMap.size(om)}, {2, 3, 2}, 'b and c left')
    T.eq(collect(OrderedMap.reveach(om)), {'b', 'c'}, 'no hole where d was')
    OrderedMap.insert(om, 'x', 'x')
    T.eq({OrderedMap.get(om, 4), OrderedMap.get_oldest(om)}, {'x', 'b'}, 'its number reused; b kept')
    OrderedMap.pop(om)
    OrderedMap.pop(om)
    OrderedMap.pop(om)
    T.eq({OrderedMap.size(om), OrderedMap.pop(om)}, {0}, 'empty, and popping more does nothing')
    T.eq(collect(OrderedMap.each(om)), {}, 'nothing to iterate')
    OrderedMap.insert(om, 'y', 'y')
    T.eq({OrderedMap.first(om), OrderedMap.last(om)}, {2, 2}, 'numbering goes on')
    OrderedMap.reset(om)
    T.eq({OrderedMap.first(om), OrderedMap.last(om), OrderedMap.size(om)}, {1, 0, 0}, 'reset')
end)

T.case('ratelimit allows a burst, then one line per interval', function()
    T.boot {}
    local ratelimit = T.require 'hub.lib.ratelimit'
    local burst, interval = 3, 2
    local t, now = 0, 100
    local waits = {}
    for _ = 1, 4 do
        table.insert(waits, ratelimit.wait(t, now, burst, interval))
        t = ratelimit.take(t, now, interval)
    end
    T.eq(waits, {0, 0, 0, 2}, 'three at once, the fourth waits an interval')
    T.eq(ratelimit.wait(t, now + 2, burst, interval), 2, 'the fifth an interval later')
    T.eq(ratelimit.wait(t, now + 4, burst, interval), 0, 'and may go then')
    T.eq(ratelimit.take(t, now + 100, interval), now + 102, 'idle time refills the burst, no further')
end)

T.run()
