-- Key codes and the key handler tables.
--
-- Keys arrive as integers: a code point, or a negated ncurses KEY_ value
-- for special keys, or a negated character for Meta combinations.

local chat      <const> = require 'hub.features.chat'
local cmdline   <const> = require 'hub.ui.cmdline'
local common    <const> = require 'hub.features.common'
local irc_model <const> = require 'hub.net.irc'
local control   <const> = require 'hub.ui.control'
local details   <const> = require 'hub.ui.details'
local editor    <const> = require 'hub.ui.editor'
local pads      <const> = require 'hub.ui.pads'
local dispatch  <const> = require 'hub.runtime.dispatch'
local log       <const> = require 'hub.runtime.log'

local M = {}

function M.ctrl(x)
    return 0x1f & string.byte(x)
end

function M.meta(x)
    return -string.byte(x)
end

local ctrl <const>, meta <const> = M.ctrl, M.meta

-- Enter in each input mode
local execute = {}

function execute.command()
    local ed = control.editor()
    local text = editor.content(ed)
    control.set_input_mode()

    if text:match '^%s*$' then
        editor.reset(ed)
        return
    end
    editor.confirm(ed)
    cmdline.execute(text)
end

function execute.filter()
    local ed = control.editor()
    control.set_filter(HUB.state.ui.input.filter_target or HUB.state.ui.view, editor.content(ed))
    editor.reset(ed)
    control.set_input_mode()
end

-- Send the line to the shown buffer with say(net, target, text)
local function talk_with(say)
    local ed = control.editor()
    local text = editor.content(ed)
    local net = control.current_net()
    local target = net and control.talk_target(net)
    control.set_input_mode()
    if text == '' then
        editor.reset(ed)
        return
    end
    editor.confirm(ed)
    if not target then
        log.add('error', 'no buffer to talk in')
        return
    end
    local ok, err = pcall(say, net, target, text)
    if not ok then
        log.add('error', '%s', err)
    end
end

function execute.talk() talk_with(chat.say) end
function execute.action() talk_with(chat.action) end
function execute.notice() talk_with(chat.notice) end

function execute.password()
    control.answer_prompt(editor.content(control.editor()))
end

-- Channel names, and nicks in the talk target when it is a channel
local function names_like(seed)
    local net = control.current_net()
    local rec = net and HUB.state.nets[net]
    local irc = rec and rec.irc
    local t = {}
    if not irc then return t end
    local function starts(s) return s:sub(1, #seed) == seed end
    for _, channel in pairs(irc.channels) do
        if starts(channel.name) then table.insert(t, channel.name) end
    end
    local target = control.talk_target(net)
    local channel = target and irc_model.is_channel_name(irc, target) and irc_model.get_channel(irc, target)
    if channel then
        for _, member in pairs(channel.members) do
            if starts(member.user.nick) then table.insert(t, member.user.nick) end
        end
    end
    return t
end

local function do_tab(dir)
    local ed = control.editor()
    editor.tab(ed, dir, function(prefix, seed)
        local t
        local command = HUB.state.ui.input.mode == 'command'
        if command and prefix == '' then
            t = cmdline.complete(seed)
        else
            t = command and cmdline.complete_args(prefix, seed) or names_like(seed)
        end
        if next(t) then
            table.sort(t)
            -- Shift-Tab starts from the last candidate
            return dir == 1 and 1 or #t, t
        end
    end)
end

local function with_editor(f)
    return function() f(control.editor()) end
end

-- Keys while an input mode is active
M.input = {
    [0x7f                  ] = with_editor(editor.backspace), -- Del
    [ctrl 'H'              ] = with_editor(editor.backspace),
    [ctrl 'D'              ] = with_editor(editor.delete),
    [ctrl 'M'              ] = function()
        local f = execute[HUB.state.ui.input.mode]
        if f then f() end
    end,
    [ctrl 'U'              ] = with_editor(editor.kill_to_beg),
    [ctrl 'K'              ] = with_editor(editor.kill_to_end),
    [ctrl 'A'              ] = with_editor(editor.move_to_beg),
    [ctrl 'E'              ] = with_editor(editor.move_to_end),
    [ctrl 'W'              ] = with_editor(editor.kill_prev_spaced_word),
    [meta 'd'              ] = with_editor(editor.kill_next_word),
    [-0x7f                 ] = with_editor(editor.kill_prev_word), -- Meta-Del
    [-ctrl 'H'             ] = with_editor(editor.kill_prev_word),
    [ctrl 'B'              ] = with_editor(editor.move_left),
    [ctrl 'F'              ] = with_editor(editor.move_right),
    [ctrl 'Y'              ] = with_editor(editor.paste),
    [meta 'y'              ] = with_editor(editor.paste_older),
    [ctrl '_'              ] = with_editor(editor.undo), -- also C-/
    [ctrl 'T'              ] = with_editor(editor.swap),
    [meta 'f'              ] = with_editor(editor.move_next_word),
    [meta 'b'              ] = with_editor(editor.move_prev_word),
    [meta 'k'              ] = with_editor(editor.hexinput),
    [meta 't'              ] = with_editor(editor.swap_words),
    [meta 'u'              ] = with_editor(editor.upcase_word),
    [meta 'l'              ] = with_editor(editor.downcase_word),
    [meta 'c'              ] = with_editor(editor.capitalize_word),
    [meta '<'              ] = with_editor(editor.oldest_history),
    [meta '>'              ] = with_editor(editor.newest_history),
    -- abandons the line or prompt, but not the view's scroll and filter
    [ctrl 'G'              ] = function()
        if control.current_prompt() then
            control.answer_prompt(nil)
            return
        end
        editor.reset(control.editor())
        control.set_input_mode()
    end,
    [-ncurses.KEY_LEFT     ] = with_editor(editor.move_left),
    [-ncurses.KEY_RIGHT    ] = with_editor(editor.move_right),
    [-ncurses.KEY_HOME     ] = with_editor(editor.move_to_beg),
    [-ncurses.KEY_END      ] = with_editor(editor.move_to_end),
    [-ncurses.KEY_BACKSPACE] = with_editor(editor.backspace),
    [-ncurses.KEY_DC       ] = with_editor(editor.delete),
    [-ncurses.KEY_UP       ] = with_editor(editor.older_history),
    [-ncurses.KEY_DOWN     ] = with_editor(editor.newer_history),
    [ctrl 'I'              ] = function() do_tab(1) end,
    [-ncurses.KEY_BTAB     ] = function() do_tab(-1) end,
}

-- Scroll by pages and lines toward older entries of a rolling log, or
-- toward the top of a document. The detail pane, while it is open, takes
-- the scrolling from the view. draw.draw_rotation and pads.set_paging
-- (ui/pads.lua) record the page size and limit.
local function scroll(pages, lines)
    return function()
        local view = control.current_view()
        local vs = control.detail() --[[@as hub.ViewState|nil]]
        local document = true
        if not vs then
            vs = control.view_state(view.id)
            document = view.document
        end
        if vs.page then
            -- a document's scroll counts rows down from its top
            local sign = document and -1 or 1
            local target = vs.scroll + sign * (pages * vs.page + lines)
            vs.scroll = math.max(0, math.min(target, vs.max_scroll))
        end
    end
end

-- Scroll sideways by most of a screen. The detail pane, while it is open,
-- takes this from the view, though only a wide kind has anything to the
-- side; the renderer (ui/init.lua, ui/details/init.lua) keeps its scroll
-- in range.
local function hscroll(direction)
    local vs
    local detail = control.detail()
    if detail then
        local kind = details.kinds[detail.kind]
        if not (kind and kind.wide) then return end
        vs = detail
    else
        vs = control.view_state(HUB.state.ui.view)
    end
    local unit = math.max(1, tty_width - 26)
    vs.hscroll = math.max(0, math.min(pads.width - tty_width, (vs.hscroll or 0) + direction * unit))
end

-- Keys when neither an input mode nor the view handled them
M.global = {
    [0x1b] = function() -- Esc
        log.dismiss()
        if control.current_prompt() then
            control.answer_prompt(nil) -- aborts the task's prompt
            return
        end
        -- outside input modes the detail pane closes first
        local input = HUB.state.ui.input
        if control.detail() and not input.mode then
            control.close_detail()
            return
        end
        -- filtering the pane, Esc clears its filter and leaves the view's
        if input.mode == 'filter' and input.filter_target == 'detail' then
            editor.reset(control.editor())
            control.set_input_mode()
            control.set_filter('detail', nil)
            return
        end
        editor.reset(control.editor())
        control.set_input_mode()
        local view = control.current_view()
        local vs = control.view_state(view.id)
        vs.scroll = 0
        vs.hscroll = 0
        vs.filter = nil
        if view.reset then view.reset(vs) end
    end,

    [-ncurses.KEY_PPAGE] = scroll(1, 0),
    [-ncurses.KEY_NPAGE] = scroll(-1, 0),
    [-ncurses.KEY_UP] = scroll(0, 1),
    [-ncurses.KEY_DOWN] = scroll(0, -1),

    [-ncurses.KEY_RESUME] = function() HUB.state.ui.focus = true end,
    [-ncurses.KEY_EXIT] = function() HUB.state.ui.focus = false end,

    [ctrl 'L'] = function() ncurses.clear() end,
    [ctrl 'N'] = control.next_view,
    [ctrl 'P'] = control.prev_view,

    [ctrl 'C'] = function() dispatch.route 'app.quit' () end,
    [ctrl 'Z'] = function() snowcone.raise(snowcone.SIGTSTP) end,

    [string.byte '/'] = function()
        editor.reset(control.editor())
        control.set_input_mode 'command'
    end,

    [ctrl 'S'] = function()
        -- a prompt is answered or aborted, not left behind
        if control.current_prompt() then return end
        editor.reset(control.editor())
        control.start_filter(details.filter_target())
    end,

    -- the next buffer of the current network with unseen messages,
    -- mentions first
    [meta 'a'] = function()
        local net = control.current_net()
        if not (net and common.enabled(net, 'chat')) then return end
        local current = control.talk_target(net)
        local best = chat.next_buffer(net, current and chat.fold(net, current) or '', true)
        if best then
            control.set_talk_target(net, best.name)
            control.set_view 'buffer'
        end
    end,

    -- back to the previous buffer, or to the buffer view
    [meta 's'] = function()
        local net = control.current_net()
        if not net then return end
        local vs = control.view_state 'buffer'
        local previous = vs.previous and vs.previous[net]
        if HUB.state.ui.view == 'buffer' and previous then
            control.set_talk_target(net, previous)
        elseif control.talk_target(net) then
            control.set_view 'buffer'
        end
    end,

    [-ncurses.KEY_RIGHT] = function() hscroll(1) end,
    [-ncurses.KEY_LEFT] = function() hscroll(-1) end,
}

-- Meta-1..9 select networks in configuration order
for i = 1, 9 do
    M.global[meta(tostring(i))] = function()
        local id = control.net_ids()[i]
        if id then control.set_current_net(id) end
    end
end

-- F1.. select the views of the current rotation
for i = 1, 12 do
    M.global[-(ncurses.KEY_F1 - 1 + i)] = function()
        local id = control.rotation()[i]
        if id then control.set_view(id) end
    end
end

return M
