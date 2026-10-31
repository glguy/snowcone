-- A channel's information in the detail pane, read live from the model
-- (net/irc.lua): topic and who set it, creation time, modes, members by
-- rank, and the list modes (bans, quiets, ...); [↻] asks the server for
-- a list, or for the modes, again or for the first time.
-- A fetched list shows its count and folds its entries behind [+]; the
-- detail keeps the open ones in open_lists. [x] removes an entry. The
-- data is {name}; the filter (Ctrl-S, /filter) shows only the members
-- and list entries that match, folded or not.

local addircstr <const> = require 'hub.ui.irc_formatting'
local chat      <const> = require 'hub.features.chat'
local control   <const> = require 'hub.ui.control'
local draw      <const> = require 'hub.ui.draw'
local fields    <const> = require 'hub.ui.fields'
local irc_model <const> = require 'hub.net.irc'
local matching  <const> = require 'hub.lib.matching'
local scrub     <const> = require 'hub.lib.scrub'

local heading <const> = fields.heading
local label   <const> = fields.label
local key     <const> = fields.key
local words   <const> = fields.words

local M = {kind = 'channel', filter = true}

M.events = {
    ['chat.show_channel'] = function(ev) return ev.net, {name = ev.target} end,
}

function M.title(detail)
    return 'channel ' .. scrub(detail.data.name)
end

-- Names of the usual list modes
local list_names <const> = {b = 'bans', q = 'quiets', e = 'excepts', I = 'invex'}

-- A time with how long ago it was
local function when(win, t)
    win:waddstr(os.date('%c', t))
    key(win, 'ago')
    win:waddstr(draw.duration(os.time() - t))
end

-- The nick of a source, or the source
local function nick_of(source)
    return source:match '^[^!]*'
end

local function members(ctx, win, irc, channel, pattern)
    -- rank by the highest prefix, by PREFIX order; none ranks last
    local ranked = {}
    local counts = {}
    for _, member in pairs(channel.members) do
        local rank, prefix = #irc.prefixes + 1, ''
        for mode in pairs(member.modes) do
            local p = irc.mode_to_prefix[mode]
            local i = p and irc.prefixes:find(p, 1, true)
            if i and i < rank then rank, prefix = i, p end
        end
        counts[prefix] = (counts[prefix] or 0) + 1
        local nick = member.user.nick
        if not pattern or matching.safematch(nick, pattern) then
            table.insert(ranked, {rank = rank, text = prefix .. nick, nick = irc_model.fold(irc, nick)})
        end
    end
    table.sort(ranked, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.nick < b.nick
    end)

    local total = 0
    for _, n in pairs(counts) do total = total + n end
    label(win, 'members')
    win:waddstr(tostring(total))
    for i = 1, #irc.prefixes do
        local p = irc.prefixes:sub(i, i)
        if counts[p] then
            key(win, p)
            win:waddstr(tostring(counts[p]))
        end
    end
    win:waddstr '\n'

    local list = {}
    for i, entry in ipairs(ranked) do list[i] = scrub(entry.text) end
    label(win, pattern and 'matching' or 'nicks')
    words(ctx, win, 'members', list, function(w, text)
        local p = text:sub(1, 1)
        if irc.prefix_to_mode[p] then
            if p == irc.prefixes:sub(1, 1) then draw.green(w) else draw.yellow(w) end
        end
    end)
end

local function list_mode(ctx, win, channel, mode, pattern)
    local name = channel.name
    local entries = channel.list_modes[mode]
    label(win, list_names[mode] or '+' .. mode)
    if not entries then
        win:waddstr 'not fetched '
        ctx.add_button(win, '[↻]', function() chat.fetch_list(ctx.net, name, mode) end)
        win:waddstr '\n'
        return
    end

    local sorted = {}
    for mask, entry in pairs(entries) do
        if not pattern or matching.safematch(mask .. ' ' .. (entry.who or ''), pattern) then
            table.insert(sorted, {mask = mask, who = entry.who, ts = tonumber(entry.ts)})
        end
    end
    -- newest first, when the server said when
    table.sort(sorted, function(a, b)
        if (a.ts or 0) ~= (b.ts or 0) then return (a.ts or 0) > (b.ts or 0) end
        return a.mask < b.mask
    end)

    local n = 0
    for _ in pairs(entries) do n = n + 1 end
    win:waddstr(pattern and string.format('%d of %d ', #sorted, n)
        or string.format('%d %s ', n, n == 1 and 'entry' or 'entries'))
    local vs = ctx.vs
    local open = vs.open_lists and vs.open_lists[mode]
    if n > 0 then
        ctx.add_button(win, open and '[-]' or '[+]', function()
            vs.open_lists = vs.open_lists or {}
            vs.open_lists[mode] = not open or nil
        end)
        win:waddstr ' '
    end
    ctx.add_button(win, '[↻]', function() chat.fetch_list(ctx.net, name, mode) end)
    win:waddstr '\n'

    -- a search shows what it finds, folded or not
    if not (open or pattern) then return end
    for _, entry in ipairs(sorted) do
        win:waddstr(string.rep(' ', fields.width + 2))
        local mask = entry.mask
        ctx.add_button(win, '[x]', function() chat.unset_list(ctx.net, name, mode, mask) end)
        win:waddstr ' '
        draw.red(win)
        win:waddstr(scrub(entry.mask))
        draw.normal(win)
        if entry.who then
            key(win, 'by')
            win:waddstr(scrub(nick_of(entry.who)))
        end
        if entry.ts then
            key(win, 'on')
            win:waddstr(os.date('%Y-%m-%d %H:%M', entry.ts))
        end
        win:waddstr '\n'
    end
end

function M.render(ctx, win)
    local name = ctx.vs.data.name
    local rec = ctx.net and HUB.state.nets[ctx.net]
    local irc = rec and rec.irc
    local channel = irc and irc_model.get_channel(irc, name)

    heading(win, scrub(channel and channel.name or name))
    if not channel then
        win:waddstr(irc and 'Not in this channel: /talk to join it\n' or 'Not connected\n')
        return
    end
    local pattern = control.filter(ctx.id)

    label(win, 'topic')
    if channel.topic and channel.topic ~= '' then
        addircstr(win, channel.topic)
    else
        win:waddstr '-'
    end
    win:waddstr '\n'
    if channel.topic_who then
        label(win, 'set by')
        win:waddstr(scrub(nick_of(channel.topic_who)))
        if channel.topic_time then
            key(win, 'on')
            when(win, channel.topic_time)
        end
        win:waddstr '\n'
    end

    label(win, 'created')
    if channel.creationtime then
        when(win, channel.creationtime)
    else
        win:waddstr '-'
    end
    win:waddstr '\n'

    -- setting modes as words, those with an argument as mode=argument
    label(win, 'modes')
    if channel.modes then
        local list = {}
        local flags = {}
        for flag in pairs(channel.modes) do table.insert(flags, flag) end
        table.sort(flags)
        for _, flag in ipairs(flags) do
            local arg = channel.modes[flag]
            table.insert(list, arg == true and flag or {flag, scrub(tostring(arg))})
        end
        if #list == 0 then
            win:waddstr '- '
        else
            for _, word in ipairs(list) do
                if type(word) == 'table' then
                    draw.cyan(win)
                    win:waddstr(word[1])
                    draw.black(win)
                    win:waddstr '='
                    draw.normal(win)
                    win:waddstr(word[2], ' ')
                else
                    draw.cyan(win)
                    win:waddstr(word, ' ')
                    draw.normal(win)
                end
            end
        end
    else
        win:waddstr 'not known '
    end
    ctx.add_button(win, '[↻]', function() chat.refresh_modes(ctx.net, name) end)
    win:waddstr '\n'

    members(ctx, win, irc, channel, pattern)

    for mode in irc.modes_A:gmatch '.' do
        list_mode(ctx, win, channel, mode, pattern)
    end
end

return M
