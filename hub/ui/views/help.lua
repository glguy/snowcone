-- Command list, by group: the views as a row of names to click, then
-- the client's commands, the connection's, and each feature's and
-- plugin's, in the order their modules list them, each with its usage
-- and help. Ctrl-S searches names, usage and help as you type; Meta-A
-- shows the commands of every feature, not just the current network's.

local cmdline   <const> = require 'hub.ui.cmdline'
local control   <const> = require 'hub.ui.control'
local draw      <const> = require 'hub.ui.draw'
local fields    <const> = require 'hub.ui.fields'
local matching  <const> = require 'hub.lib.matching'
local scrub     <const> = require 'hub.lib.scrub'

-- Groups in the order shown, with their headings; any other group (a
-- plugin's, or a feature without one here) follows, by name
local group_order <const> = {
    {'client', 'Client'},
    {'connection', 'Connection'},
    {'chat', 'Chat'},
    {'snotice', 'Server notices'},
    {'oper', 'Operator'},
    {'topology', 'Topology'},
    {'keys', 'Services keys'},
}

-- The widest name and usage before the help starts a row of its own
local max_width <const> = 36

local function title_of(group)
    for _, g in ipairs(group_order) do
        if g[1] == group then return g[2] end
    end
    return (group:gsub('^%l', string.upper))
end

-- What the search matches: the name, usage and help, and the group
local function haystack(cmd)
    return table.concat({cmd.name, cmd.usage or '', cmd.help or '', title_of(cmd.group or '')}, ' ')
end

-- The commands to show, by group, each group in order
local function gather(ctx, pattern)
    local by_group = {}
    for _, cmd in pairs(HUB.current.commands) do
        if (ctx.vs.all or cmdline.available(cmd))
        and (not pattern or matching.safematch(haystack(cmd), pattern)) then
            local group = cmd.group or 'other'
            local list = by_group[group]
            if not list then
                list = {}
                by_group[group] = list
            end
            table.insert(list, cmd)
        end
    end
    for _, list in pairs(by_group) do
        table.sort(list, function(a, b) return a.order < b.order end)
    end
    return by_group
end

-- The views as a row of names that show them, by name, wrapping under an
-- indent
local function views_row(ctx, win, views)
    table.sort(views, function(a, b) return a.name < b.name end)
    fields.heading(win, 'Views')
    win:waddstr '  '
    for i, cmd in ipairs(views) do
        local text = '/' .. cmd.name
        local _, x = ncurses.getyx(win)
        -- a name ends before the last column
        if i > 1 and x + 1 + #text >= ctx.cols then
            win:waddstr '\n  '
        elseif i > 1 then
            win:waddstr ' '
        end
        draw.bold(win)
        ctx.add_button(win, text, function() cmdline.execute(cmd.name) end, true)
        draw.normal(win)
    end
    win:waddstr '\n'
end

-- Words from the cursor, wrapping under column `indent`; a word ends
-- before the last column, which would move the cursor to the next row
local function wrap(win, text, indent, cols)
    local first = true
    for word in text:gmatch '%S+' do
        local _, x = ncurses.getyx(win)
        local len = utf8.len(word) or #word
        if not first and x + 1 + len >= cols then
            win:waddstr('\n', string.rep(' ', indent))
        elseif not first then
            win:waddstr ' '
        end
        win:waddstr(word)
        first = false
    end
    win:waddstr '\n'
end

local function command_row(win, cmd, width, cols)
    local left = '/' .. cmd.name .. (cmd.usage and ' ' .. cmd.usage or '')
    win:waddstr '  '
    draw.bold(win)
    win:waddstr('/', cmd.name)
    draw.normal(win)
    if cmd.usage then
        draw.blue(win)
        win:waddstr(' ', scrub(cmd.usage))
        draw.normal(win)
    end
    -- a long usage puts the help on the next row
    local len = utf8.len(left) or #left
    if len > width then
        win:waddstr('\n', string.rep(' ', width + 2))
    else
        win:waddstr(string.rep(' ', width - len))
    end
    if cmd.scope == 'net' then
        draw.cyan(win)
        win:waddstr ' net '
        draw.normal(win)
    else
        win:waddstr '     '
    end
    wrap(win, scrub(cmd.help or ''), width + 7, cols)
end

return {
    id = 'help',
    keypress = function(ctx, key)
        if key == -string.byte 'a' then
            ctx.vs.all = not ctx.vs.all
            return true
        end
    end,

    modes = function(ctx)
        return {ctx.vs.all and 'all' or nil}
    end,

    title = 'help',
    scope = 'global',
    document = true,

    render = function(ctx, win)
        draw.magenta(win)
        draw.bold(win)
        win:waddstr 'Commands'
        draw.normal(win)
        win:waddstr '   (C-s: search; Meta-A: all features; /name@net: on another network)\n'

        local pattern = control.filter(ctx.id)
        local by_group = gather(ctx, pattern)

        local any_views = by_group.views ~= nil
        if any_views then
            views_row(ctx, win, by_group.views)
            by_group.views = nil
        end

        -- one column for every group's names and usages
        local width = 0
        for _, list in pairs(by_group) do
            for _, cmd in ipairs(list) do
                local left = '/' .. cmd.name .. (cmd.usage and ' ' .. cmd.usage or '')
                local len = utf8.len(left) or #left
                if len <= max_width and len > width then width = len end
            end
        end

        -- the known groups in their order, then the rest by name
        local order, known = {}, {}
        for _, g in ipairs(group_order) do
            known[g[1]] = true
            if by_group[g[1]] then table.insert(order, g[1]) end
        end
        local others = {}
        for group in pairs(by_group) do
            if not known[group] then table.insert(others, group) end
        end
        table.sort(others)
        for _, group in ipairs(others) do table.insert(order, group) end

        for _, group in ipairs(order) do
            fields.heading(win, title_of(group))
            for _, cmd in ipairs(by_group[group]) do
                command_row(win, cmd, width, ctx.cols)
            end
        end

        if #order == 0 and not any_views then
            win:waddstr '\nNo command matches\n'
        end
    end,
}
