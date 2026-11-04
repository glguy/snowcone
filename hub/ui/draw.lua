-- Drawing helpers: attribute and color setters and the rotating log
-- display.

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
        local color <const> = ncurses['COLOR_' .. name:upper()]
        M[name] = function(w) colorset(color, nil, w) end
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

--- The source column of one of our own messages, and its color setter:
--- '>>>', or marked while the rate limit holds its line back, or once the
--- line was dropped unsent (msg.delivery, net/send.lua); yellow while the
--- server hasn't confirmed it, and marked when it refused it or never said
--- (msg.receipt, features/chat).
function M.outbound(msg)
    local state = msg.delivery and msg.delivery.state
    if state == 'queued' then
        return 'queued >>>', M.yellow
    elseif state == 'dropped' then
        return 'unsent >>>', M.red
    end
    local receipt = msg.receipt
    if receipt == 'awaiting' then
        return '>>>', M.yellow
    elseif receipt == 'rejected' then
        return 'refused >>>', M.red
    elseif receipt == 'unknown' then
        return 'unconfirmed >>>', M.yellow
    end
    return '>>>', M.red
end

-- Times a server sends are only text: anything past a few centuries
-- isn't a time
local max_seconds <const> = 1e10

--- A length of time in a few characters: 45s, 12m, 3h 20m, 2d 4h; ?
--- for what isn't a sane length.
function M.duration(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds ~= seconds or math.abs(seconds) > max_seconds then return '?' end
    seconds = math.floor(seconds)
    if seconds < 120 then return seconds .. 's' end
    if seconds < 7200 then return seconds // 60 .. 'm' end
    if seconds < 172800 then return string.format('%dh %dm', seconds // 3600, seconds % 3600 // 60) end
    return string.format('%dd %dh', seconds // 86400, seconds % 86400 // 3600)
end

--- A time (epoch seconds, as a number or text) formatted by os.date, or ?
--- for what isn't a sane time.
---@param fmt string
---@param t any
---@return string
function M.date(fmt, t)
    t = math.tointeger(tonumber(t))
    if not t or math.abs(t) > max_seconds then return '?' end
    local ok, text = pcall(os.date, fmt, t)
    return ok and text --[[@as string]] or '?'
end

-- The characters of text, one string each: a byte and the continuation
-- bytes after it, so pieces of a text split at ASCII count as the whole
-- does, valid UTF-8 or not
local function characters(text)
    local list = {}
    for c in text:gmatch '[%z\1-\x7f\xc0-\xff]?[\x80-\xbf]*' do
        if c ~= '' then table.insert(list, c) end
    end
    return list
end

--- Where text drawn from column `x` wraps at spaces to continue at column
--- `indent` of the next row, so each row ends before column `cols`: a
--- list of breaks {from, to, newline} by character, in order. Characters
--- from..to (spaces, maybe none) aren't drawn, and with newline the
--- character after them starts the next row. A word too long for a row is
--- broken where it must be.
---@param text string
---@param x integer
---@param cols integer
---@param indent integer
---@return {from: integer, to: integer, newline: boolean}[]
function M.wrap_breaks(text, x, cols, indent)
    -- writing the last column moves the cursor to the next row, so a row
    -- ends a column before it
    local room = cols - 1
    local breaks, pos = {}, 0
    local chars = characters(text)
    local i = 1
    while i <= #chars do
        local gap, len = 0, 0
        while chars[i + gap] == ' ' do gap = gap + 1 end
        while chars[i + gap + len] and chars[i + gap + len] ~= ' ' do len = len + 1 end
        if len > 0 and x > indent and x + gap + len > room then
            table.insert(breaks, {from = pos + 1, to = pos + gap, newline = true})
            x = indent
        else
            -- spaces past the end of the row aren't drawn
            local drawn = math.min(gap, math.max(0, room - x))
            if drawn < gap then
                table.insert(breaks, {from = pos + drawn + 1, to = pos + gap, newline = false})
            end
            x = x + drawn
        end
        pos = pos + gap
        i = i + gap + len
        -- a word longer than a whole row
        while x + len > room and room > indent do
            local fits = room - x
            pos, len, x = pos + fits, len - fits, indent
            table.insert(breaks, {from = pos + 1, to = pos, newline = true})
        end
        pos, x = pos + len, x + len
    end
    return breaks
end

--- A function that draws text at the cursor in pieces, as one text
--- broken at `breaks` (wrap_breaks) would be, continuing rows at column
--- `indent`.
---@param win ncurses.Window
---@param breaks {from: integer, to: integer, newline: boolean}[]
---@param indent integer
---@return fun(text: string)
function M.wrapper(win, breaks, indent)
    local seen, next_break = 0, 1
    return function(text)
        local run = {}
        for _, c in ipairs(characters(text)) do
            seen = seen + 1
            local b = breaks[next_break]
            if b and seen == b.to + 1 and b.newline then
                win:waddstr(table.concat(run))
                run = {}
                win:waddstr '\n'
                win:wmove(ncurses.getyx(win), indent)
            end
            while b and seen > b.to do
                next_break = next_break + 1
                b = breaks[next_break]
            end
            if not (b and seen >= b.from and seen <= b.to) then
                table.insert(run, c)
            end
        end
        win:waddstr(table.concat(run))
    end
end

--- Draw text at the cursor, wrapping at spaces to continue at column
--- `indent` of the next row, so each row ends before column `cols`, as
--- wrap_breaks has it. Text is already scrubbed.
---@param win ncurses.Window
---@param text string
---@param cols integer
---@param indent integer
function M.wrap_text(win, text, cols, indent)
    local _, x = ncurses.getyx(win)
    M.wrapper(win, M.wrap_breaks(text, x, cols, indent), indent)(text)
end

--- Draw an HH:MM:SS time whose digits brighten for the first seconds.
---@param win ncurses.Window
---@param timestamp number clock.now() when the entry arrived
---@param time string HH:MM:SS
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
-- entries arrive. While scrolled back, vs.pin holds the number of the
-- newest entry from when scrolling started, so the viewport stays put as
-- entries arrive; the scroll counts the shown (matching) entries back from
-- it. The pin is the view's, not the map's, so two views of one map don't
-- fight over it. Returns the window and the number of matching entries up
-- to the pin, for the scroll limit.
local function rotating_window(vs, source, rows, predicate)
    OrderedMap.set_predicate(source, predicate)

    local newest, skip, divider
    if vs.scroll > 0 then
        -- a map emptied since (OrderedMap.reset) numbers from 1 again
        newest = math.min(vs.pin or source.n, source.n)
        vs.pin = newest
        skip = vs.scroll
        divider = rows - 1
    else
        vs.pin = nil
        newest = source.n
        skip = 0
        divider = source.ticker
    end

    local window = {}
    local n, matching = 0, 0
    for entry in OrderedMap.each(source, source.n - newest) do
        if not predicate or predicate(entry) then
            matching = matching + 1
            if skip > 0 then
                skip = skip - 1
            elseif n + 1 < rows then -- saves a row for divider
                window[(divider - 1 - n) % rows + 1] = entry
                n = n + 1
            elseif not predicate then
                -- the rest are counted without testing each
                matching = newest - OrderedMap.first(source) + 1
                break
            end
        end
    end

    if rows > 0 then
        window[divider % rows + 1] = 'divider'
    end
    return window, matching
end

--- Draw entries of an OrderedMap as a rotating log. It records the page
--- size and the scroll limit in vs for the paging keys (ui/keymap.lua).
---@param win ncurses.Window
---@param vs hub.ViewState scroll is read, and pin maintained here
---@param start integer first row
---@param rows integer
---@param data hub.OrderedMap entries with time and timestamp
---@param show_entry (fun(entry: table): boolean)|nil selects entries
---@param draw_entry fun(win: ncurses.Window, entry: table) draws after the time
function M.draw_rotation(win, vs, start, rows, data, show_entry, draw_entry)
    -- one row is the divider; a page keeps one entry in view
    vs.page = math.max(1, rows - 2)
    local window, matching = rotating_window(vs, data, rows, show_entry)
    vs.max_scroll = math.max(0, matching - (rows - 1))
    local last_time
    for i = 1, rows do
        local entry = window[i]
        local y = start + i - 1
        win:wmove(y, 0)
        if entry == 'divider' then
            last_time = os.date '!%H:%M:%S' --[[@as string]]
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
