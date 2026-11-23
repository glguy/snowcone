-- The look of the chrome: the colors of the status bar's band and of
-- buttons, and the glyphs between the bar's fragments and at the ends of
-- buttons.
--
-- ui.theme picks the colors: 'modern' (the default), on terminals of 256
-- colors or more, where a color needn't come from the terminal's palette,
-- draws the bar as a band of dark gray and buttons as chips of color;
-- 'classic', as on terminals of fewer colors, leaves the bar on the
-- terminal's background and draws buttons in brackets in reverse video.
--
-- ui.separators picks the glyphs, which need a Powerline or Nerd font but
-- for 'plain': 'powerline' (the default) triangles, 'rounded' half
-- circles, which also round the ends of chips, 'slant' diagonals, and
-- 'plain', a bar between fragments that share a background and nothing
-- where the background changes.

local colors <const> = require 'hub.ui.colors'

local M = {}

-- Glyph sets: `right` between fragments of different backgrounds, drawn in
-- the old one on the new, and `right_thin` between fragments of one; a
-- set with `cap_left` and `cap_right` ends chips with them in place of
-- their padding
M.glyph_sets = {
    powerline = {right = utf8.char(0xE0B0), right_thin = utf8.char(0xE0B1)},
    rounded   = {right = utf8.char(0xE0B4), right_thin = utf8.char(0xE0B5),
                 cap_left = utf8.char(0xE0B6), cap_right = utf8.char(0xE0B4)},
    slant     = {right = utf8.char(0xE0BC), right_thin = utf8.char(0x2571)},
    plain     = {right = '',                right_thin = '│'},
}

-- The band's background and the text on it, by RGB
local surface_rgb <const> = 0x303446
local text_rgb    <const> = 0xc6d0f5

-- Text by role, by RGB: muted for what is there but not to be read
-- first, heading for the headers of tables
local text_role_rgb <const> = {
    muted   = 0x737994,
    heading = 0x8caaee,
}

-- Chips by role, {background, text} by RGB: neutral for settings and
-- most actions, accent for the choice in effect, and ok, warn and danger
-- for what an action does
local dark_rgb <const> = 0x232634
local chip_rgb <const> = {
    neutral = {0x51576d, text_rgb},
    accent  = {0x8caaee, dark_rgb},
    ok      = {0xa6d189, dark_rgb},
    warn    = {0xe5c890, dark_rgb},
    danger  = {0xe78284, dark_rgb},
}

-- Chips by role on the classic theme: the draw.lua color setter whose
-- color is reversed, none for neutral, which keeps the color already set
M.classic_chip = {
    accent = 'blue',
    ok     = 'green',
    warn   = 'yellow',
    danger = 'red',
}

local function ui_config()
    local cfg = HUB.state.config
    return cfg and cfg.ui or {}
end

--- The glyphs between fragments, by ui.separators.
---@return {right: string, right_thin: string, cap_left: string|nil, cap_right: string|nil}
function M.glyphs()
    return M.glyph_sets[ui_config().separators or 'powerline']
end

--- The background of the status bar's band and the color of text on it,
--- or nil when the bar is on the terminal's background.
---@return integer|nil surface
---@return integer|nil text
function M.surface()
    if not M.modern() then return nil end
    local count = ncurses.COLORS
    return colors.rgb(surface_rgb, count), colors.rgb(text_rgb, count)
end

--- Whether the modern colors are in use: by ui.theme, on a terminal that
--- has them.
---@return boolean
function M.modern()
    return ncurses.COLORS >= 256 and ui_config().theme ~= 'classic'
end

--- The color of text of a role, or nil on the classic theme.
---@param role 'muted'|'heading'
---@return integer|nil
function M.text(role)
    if not M.modern() then return nil end
    return colors.rgb(text_role_rgb[role], ncurses.COLORS)
end

--- The text and background of a chip of a role, or nil on the classic
--- theme.
---@param role 'neutral'|'accent'|'ok'|'warn'|'danger'
---@return integer|nil fore
---@return integer|nil back
function M.chip(role)
    if not M.modern() then return nil end
    local count = ncurses.COLORS
    local c = chip_rgb[role] or chip_rgb.neutral
    return colors.rgb(c[2], count), colors.rgb(c[1], count)
end

return M
