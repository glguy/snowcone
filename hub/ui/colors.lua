-- Terminal color numbers for IRC colors and RGB values, for a terminal
-- of a given number of colors (ncurses.COLORS):
--
--   2^24  direct color: the number is 0xRRGGBB
--   256   the nearest in the 6x6x6 cube or the gray ramp
--   16    the nearest of the 16 ANSI colors
--   8     the nearest of the 8
--
-- -1 is the terminal's default color.

local M = {}

local DIRECT <const> = 0x1000000

-- xterm's ANSI colors, for finding the nearest of them
local ansi <const> = {
    [0] = 0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
          0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
}

-- IRC colors 0-15 as ANSI colors, on terminals of 16 colors and of 8;
-- these follow the terminal's palette rather than fixed RGB values
local irc_16 <const> = {
    [0] = 15, 0, 4, 2, 9, 1, 5, 3, 11, 10, 6, 14, 12, 13, 8, 7,
}
local irc_8 <const> = {
    [0] = 7, 0, 4, 2, 1, 1, 5, 3, 3, 2, 6, 6, 4, 5, 7, 7,
}

-- IRC colors 16-98 as RGB, and as xterm 256-color indices, from 1
local irc_rgb <const> = {
    0x470000, 0x472100, 0x474700, 0x324700, 0x004700, 0x00472c, 0x004747, 0x002747,
    0x000047, 0x2e0047, 0x470047, 0x47002a, 0x740000, 0x743a00, 0x747400, 0x517400,
    0x007400, 0x007449, 0x007474, 0x004074, 0x000074, 0x4b0074, 0x740074, 0x740045,
    0xb50000, 0xb56300, 0xb5b500, 0x7db500, 0x00b500, 0x00b571, 0x00b5b5, 0x0063b5,
    0x0000b5, 0x7500b5, 0xb500b5, 0xb5006b, 0xff0000, 0xff8c00, 0xffff00, 0xb2ff00,
    0x00ff00, 0x00ffa0, 0x00ffff, 0x008cff, 0x0000ff, 0xa500ff, 0xff00ff, 0xff0098,
    0xff5959, 0xffb459, 0xffff71, 0xcfff60, 0x6fff6f, 0x65ffc9, 0x6dffff, 0x59b4ff,
    0x5959ff, 0xc459ff, 0xff66ff, 0xff59bc, 0xff9c9c, 0xffd39c, 0xffff9c, 0xe2ff9c,
    0x9cff9c, 0x9cffdb, 0x9cffff, 0x9cd3ff, 0x9c9cff, 0xdc9cff, 0xff9cff, 0xff94d3,
    0x000000, 0x131313, 0x282828, 0x363636, 0x4d4d4d, 0x656565, 0x818181, 0x9f9f9f,
    0xbcbcbc, 0xe2e2e2, 0xffffff,
}
local irc_256 <const> = {
     52,  94, 100,  58,  22,  29,  23,  24,  17,  54,  53,  89,  88, 130, 142,  64,
     28,  35,  30,  25,  18,  91,  90, 125, 124, 166, 184, 106,  34,  49,  37,  33,
     19, 129, 127, 161, 196, 208, 226, 154,  46,  86,  51,  75,  21, 171, 201, 198,
    203, 215, 227, 191,  83, 122,  87, 111,  63, 177, 207, 205, 217, 223, 229, 193,
    157, 158, 159, 153, 147, 183, 219, 212,  16, 233, 235, 237, 239, 241, 244, 247,
    250, 254, 231,
}

local function distance(a, b)
    local dr = (a >> 16) - (b >> 16)
    local dg = (a >> 8 & 0xff) - (b >> 8 & 0xff)
    local db = (a & 0xff) - (b & 0xff)
    return dr * dr + dg * dg + db * db
end

local function nearest_ansi(rgb, count)
    local best, best_d = 0, math.huge
    for i = 0, count - 1 do
        local d = distance(rgb, ansi[i])
        if d < best_d then best, best_d = i, d end
    end
    return best
end

-- The xterm cube's levels, and the index of the nearest to a channel
local levels <const> = {[0] = 0, 95, 135, 175, 215, 255}
local function level(c)
    if c < 48 then return 0 end
    if c < 115 then return 1 end
    return (c - 35) // 40
end

local function nearest_256(rgb)
    local r, g, b = rgb >> 16, rgb >> 8 & 0xff, rgb & 0xff
    local ri, gi, bi = level(r), level(g), level(b)
    local cube = levels[ri] << 16 | levels[gi] << 8 | levels[bi]
    -- the gray ramp runs from 8 to 238 in steps of 10
    local gi_ = math.max(0, math.min(23, ((r + g + b) // 3 - 3) // 10))
    local v = 8 + 10 * gi_
    local gray = v << 16 | v << 8 | v
    if distance(rgb, gray) < distance(rgb, cube) then
        return 232 + gi_
    end
    return 16 + 36 * ri + 6 * gi + bi
end

--- The terminal color for an RGB value.
---@param rgb integer 0xRRGGBB
---@param colors integer
---@return integer
function M.rgb(rgb, colors)
    if colors >= DIRECT then
        -- direct-color terminfo takes small numbers as palette indices
        -- (below 8, 16 or 256, by entry); a step of green moves past them
        if rgb < 256 then return rgb | 0x100 end
        return rgb
    elseif colors >= 256 then
        return nearest_256(rgb)
    elseif colors >= 16 then
        return nearest_ansi(rgb, 16)
    end
    return nearest_ansi(rgb, 8)
end

-- IRC colors 0-15 that are light in the usual palette
local light_16 <const> = {[0] = true, [7] = true, [8] = true, [9] = true, [10] = true, [11] = true, [15] = true}

--- An IRC color, 0 to 98, is light: dark text reads on it.
---@param n integer
---@return boolean
function M.light(n)
    if n < 16 then return light_16[n] == true end
    local rgb = irc_rgb[n - 15]
    -- perceived brightness, from 0 to 255
    return (299 * (rgb >> 16) + 587 * (rgb >> 8 & 0xff) + 114 * (rgb & 0xff)) // 1000 >= 128
end

--- The terminal color for an IRC color, 0 to 99.
---@param n integer
---@param colors integer
---@return integer
function M.irc(n, colors)
    if n == 99 then
        return -1
    elseif n < 16 then
        if colors < 16 then return irc_8[n] end
        local i = irc_16[n]
        -- every direct-color entry keeps 0-7 as palette indices
        if colors >= DIRECT and i >= 8 then return M.rgb(ansi[i], colors) end
        return i
    elseif colors >= 256 and colors < DIRECT then
        return irc_256[n - 15]
    end
    return M.rgb(irc_rgb[n - 15], colors)
end

return M
