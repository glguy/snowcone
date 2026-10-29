-- Labelled fields for document views (/stats, /session): a green heading
-- per section, a blue right-aligned label per row, and blue keys for the
-- further values of a row. Lists show their first row and fold the rest
-- behind a button.

local draw <const> = require 'hub.ui.draw'

local M = {}

-- Width of a row's label; values start two columns after it
M.width = 10
local indent <const> = string.rep(' ', M.width + 2)

local function width(text)
    return utf8.len(text) or #text
end

-- A word, or a {key, value} pair shown as key=value
local function word_width(word)
    if type(word) == 'table' then
        return width(word[1]) + 1 + width(word[2])
    end
    return width(word)
end

--- Start a section, after a blank line unless it is the first.
function M.heading(win, text)
    local y, x = ncurses.getyx(win)
    if y > 0 or x > 0 then
        win:waddstr '\n'
    end
    draw.green(win)
    draw.bold(win)
    win:waddstr(text, '\n')
    draw.normal(win)
end

--- Start a row.
function M.label(win, text)
    draw.blue(win)
    win:waddstr(string.format('%' .. M.width .. 's: ', text))
    draw.normal(win)
end

--- Name a further value of the row; the first value needs no key.
function M.key(win, text)
    local _, x = ncurses.getyx(win)
    draw.blue(win)
    win:waddstr(x > M.width + 2 and '  ' or '', text, ' ')
    draw.normal(win)
end

--- Write words, wrapping under the value column. Unless expanded, only
--- the first row shows, ending in a button that expands the rest; the
--- view state remembers which lists are open in vs.expanded[id].
---@param ctx hub.ViewContext
---@param win ncurses.Window
---@param id string names the list in the view state
---@param list any[] words, or {key, value} pairs drawn with a muted '='
--- between; already scrubbed
---@param colour_of fun(win: ncurses.Window, text: string)|nil sets the colour
--- of a word, or of both halves of a pair from its key
function M.words(ctx, win, id, list, colour_of)
    if #list == 0 then
        win:waddstr '-\n'
        return
    end

    local vs = ctx.vs
    local expanded = vs.expanded and vs.expanded[id]
    local function toggle()
        vs.expanded = vs.expanded or {}
        vs.expanded[id] = not expanded or nil
    end

    local _, x = ncurses.getyx(win)
    local total = x
    for _, word in ipairs(list) do total = total + word_width(word) + 1 end
    local folds = total > ctx.cols
    -- room for the widest button
    local reserve = folds and not expanded and width(string.format('[+%d more]', #list)) or 0

    -- a word and its space must fit before the right edge: writing the
    -- last column moves the cursor to the start of the next row
    for i, word in ipairs(list) do
        _, x = ncurses.getyx(win)
        if x + word_width(word) + 1 + reserve > ctx.cols then
            if not expanded then
                ctx.add_button(win, string.format('[+%d more]', #list - i + 1), toggle)
                break
            end
            win:waddstr('\n', indent)
        end
        local text = type(word) == 'table' and word[1] or word
        draw.normal(win)
        if colour_of then colour_of(win, text) end
        win:waddstr(text)
        if type(word) == 'table' then
            draw.black(win)
            win:waddstr '='
            draw.normal(win)
            if colour_of then colour_of(win, text) end
            win:waddstr(word[2])
        end
        draw.normal(win)
        win:waddstr ' '
    end
    if folds and expanded then
        _, x = ncurses.getyx(win)
        if x + width '[less]' + 1 > ctx.cols then
            win:waddstr('\n', indent)
        end
        ctx.add_button(win, '[less]', toggle)
    end
    win:waddstr '\n'
end

return M
