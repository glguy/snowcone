-- Drawing helpers: attribute and colour setters (globals in ircc and the
-- dashboard) and the rotating log display from ircc/utils/drawing.lua.

local OrderedMap <const> = require 'hub.lib.OrderedMap'
local clock      <const> = require 'hub.runtime.clock'

local M = {}

do
    local attrset  <const> = ncurses.attrset
    local attron   <const> = ncurses.attron
    local attroff  <const> = ncurses.attroff
    local colorset <const> = ncurses.colorset

    local WA_NORMAL    <const> = ncurses.WA_NORMAL
    local WA_BOLD      <const> = ncurses.WA_BOLD
    local WA_ITALIC    <const> = ncurses.WA_ITALIC
    local WA_REVERSE   <const> = ncurses.WA_REVERSE
    local WA_UNDERLINE <const> = ncurses.WA_UNDERLINE

    function M.normal(w)        attrset(WA_NORMAL, 0, w)   end
    function M.bold(w)          attron(WA_BOLD, w)         end
    function M.bold_(w)         attroff(WA_BOLD, w)        end
    function M.italic(w)        attron(WA_ITALIC, w)       end
    function M.italic_(w)       attroff(WA_ITALIC, w)      end
    function M.reversevideo(w)  attron(WA_REVERSE, w)      end
    function M.reversevideo_(w) attroff(WA_REVERSE, w)     end
    function M.underline(w)     attron(WA_UNDERLINE, w)    end
    function M.underline_(w)    attroff(WA_UNDERLINE, w)   end

    for _, name in ipairs {'red', 'green', 'blue', 'cyan', 'black', 'magenta', 'yellow', 'white'} do
        local colour <const> = ncurses['COLOR_' .. name:upper()]
        M[name] = function(w) colorset(colour, nil, w) end
    end
end

local divider_string <const> =
--  00:00:00
           "········································································\z
    1···············································································\z
    2···············································································\z
    3···············································································\z
    4···············································································\z
    5···············································································\z
    6·····································································"

local scrolled_divider_string <const> =
--  00:00:00
           "··↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    1·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    2·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    3·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    4·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    5·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·\z
    6·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·↓·"

--- Draw an HH:MM:SS time whose digits brighten for the first seconds.
---@param timestamp number clock.now() when the entry arrived
function M.fade_time(win, timestamp, time)
    local age = math.max(0, math.floor(clock.now() - timestamp))
    if age < 8 then
        M.white(win)
        win:waddstr(string.sub(time, 1, 8 - age))
        M.cyan(win)
        win:waddstr(string.sub(time, 9 - age, 8))
    else
        M.cyan(win)
        win:waddstr(time)
    end
end

-- Lay out a rolling window of entries around a divider that rotates as new
-- entries arrive. While scrolled back, vs.pin holds the map's ticker from
-- when scrolling started so the viewport stays put. (ircc kept the pin on
-- the map itself, which two views of one map would fight over.)
local function rotating_window(vs, source, rows, predicate)
    OrderedMap.set_predicate(source, predicate)

    local offset, divider
    if vs.scroll > 0 then
        local pin = vs.pin or source.ticker
        vs.pin = pin
        offset = vs.scroll + source.ticker - pin
        divider = rows - 1
    else
        vs.pin = nil
        divider = source.ticker
        offset = 0
    end

    if rows <= 0 then return {} end

    local n = 0
    local window = {}

    for entry in OrderedMap.each(source, offset) do
        if n + 1 >= rows then break end -- saves a row for divider
        if not predicate or predicate(entry) then
            window[(divider - 1 - n) % rows + 1] = entry
            n = n + 1
        end
    end

    window[divider % rows + 1] = 'divider'
    return window
end

--- Draw entries of an OrderedMap as a rotating log.
---@param vs table view state with scroll (and pin, maintained here)
---@param data table OrderedMap of entries with time and timestamp
---@param show_entry function|nil predicate selecting entries
---@param draw_entry function draw_entry(win, entry) draws after the time
function M.draw_rotation(win, vs, start, rows, data, show_entry, draw_entry)
    local window = rotating_window(vs, data, rows, show_entry)
    local last_time
    for i = 1, rows do
        local entry = window[i]
        local y = start + i - 1
        win:wmove(y, 0)
        if entry == 'divider' then
            last_time = os.date '!%H:%M:%S'
            M.yellow(win)
            win:waddstr(last_time, vs.scroll == 0 and divider_string or scrolled_divider_string)
        elseif entry then
            M.normal(win)
            local time = entry.time
            if time == last_time then
                win:waddstr '        '
            else
                last_time = time
                M.fade_time(win, entry.timestamp or 0, entry.time)
            end
            M.normal(win)
            draw_entry(win, entry)
        end
    end
end

return M
