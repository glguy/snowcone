-- The terminal's window title: unseen chat on any network first, so it
-- survives a tab cutting the title short, then snowcone, the current
-- network and what the view shows. A view's terminal_title(ctx) says what
-- it shows (the buffer view, its target); otherwise its title stands in.
--
--     ! snowcone - libera #snowcone
--
-- ! is a mention waiting on some network and + other unseen messages, as
-- in the status bar.

local control   <const> = require 'hub.ui.control'
local scrub     <const> = require 'hub.lib.scrub'
local statusbar <const> = require 'hub.ui.statusbar'
local tty       <const> = require 'hub.runtime.tty'

local M = {}

-- Characters of the title kept; terminals differ on longer ones
local max_length <const> = 100

local marker_text <const> = {mention = '! ', activity = '+ '}

local function marker()
    local seen
    for _, id in ipairs(control.net_ids()) do
        local a = statusbar.activity(id)
        if a == 'mention' then return a end
        seen = seen or a
    end
    return seen
end

--- The title for a view.
---@param view table the current view
---@param ctx hub.ViewContext of the current view
---@return string
function M.title(view, ctx)
    local shows
    if view.terminal_title then
        shows = control.attempt(control.disable_view, view, view.terminal_title, ctx)
    end
    if type(shows) ~= 'string' then
        shows = view.title or view.id
    end

    local parts = {}
    local m = marker()
    if m then table.insert(parts, marker_text[m]) end
    table.insert(parts, 'snowcone - ')
    if ctx.net then
        table.insert(parts, ctx.net .. ' ')
    end
    table.insert(parts, shows)

    local title = scrub(table.concat(parts))
    local cut = utf8.offset(title, max_length + 1)
    if cut and cut <= #title then
        title = title:sub(1, cut - 1)
    end
    return title
end

--- Write the title for the view, if it changed.
---@param view table
---@param ctx hub.ViewContext
function M.update(view, ctx)
    tty.set_title(M.title(view, ctx))
end

return M
