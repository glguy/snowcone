-- mytoml.to_toml output reads back as the same values.
-- Run with:  snowcone script tests/test-toml.lua

local function round_trip(v)
    local text = assert(mytoml.to_toml {a = v})
    local back = assert(mytoml.parse_toml(text), text)
    return back.a, text
end

-- Booleans stay booleans (F-115)
for _, b in ipairs {true, false} do
    local back, text = round_trip(b)
    assert(back == b, text)
end

-- Floats read back exactly, as floats, with no more digits than needed (F-116)
local floats = {
    0.1, 0.1 + 0.2, 1 / 3, 3.0, -0.0, 1.5, 2 ^ 53 + 0.0, 1e100, 1e-300,
    1.7976931348623157e308, 123456789.123456789, math.pi,
}
math.randomseed(1)
for _ = 1, 1000 do
    floats[#floats + 1] = (math.random() - 0.5) * 10 ^ math.random(-300, 300)
end
for _, x in ipairs(floats) do
    local back, text = round_trip(x)
    assert(math.type(back) == 'float' and back == x, ('%.17g: %s'):format(x, text))
    assert(1 / back == 1 / x, 'sign of zero lost: ' .. text)
end
assert(select(2, round_trip(0.1)) == 'a = 0.1\n\n')

-- Non-finite floats
assert(round_trip(1 / 0) == 1 / 0)
assert(round_trip(-1 / 0) == -1 / 0)
local nan = round_trip(0 / 0)
assert(nan ~= nan)

-- Integers stay integers
for _, i in ipairs {0, -1, math.maxinteger, math.mininteger} do
    local back, text = round_trip(i)
    assert(math.type(back) == 'integer' and back == i, text)
end
