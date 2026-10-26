-- Key codes and the key handler tables (from ircc handlers/keyboard.lua
-- and handlers/input.lua).
--
-- Keys arrive as integers: a code point, or a negated ncurses KEY_ value
-- for special keys, or a negated character for Meta combinations.

local cmdline <const> = require 'hub.ui.cmdline'
local control <const> = require 'hub.ui.control'
local editor  <const> = require 'hub.ui.editor'
local log     <const> = require 'hub.runtime.log'

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

local function do_tab(dir)
    local ed = control.editor()
    editor.tab(ed, dir, function(prefix, seed)
        if HUB.state.ui.input.mode == 'command' and prefix == '' then
            local t = cmdline.complete(seed)
            if next(t) then
                return 1, t
            end
        end
    end)
end

local function with_editor(f)
    return function() f(control.editor()) end
end

-- Keys while an input mode is active
M.input = {
    [0x7f                  ] = with_editor(editor.backspace), -- Del
    [ctrl 'M'              ] = function()
        local f = execute[HUB.state.ui.input.mode]
        if f then f() end
    end,
    [ctrl 'U'              ] = with_editor(editor.kill_to_beg),
    [ctrl 'K'              ] = with_editor(editor.kill_to_end),
    [ctrl 'A'              ] = with_editor(editor.move_to_beg),
    [ctrl 'E'              ] = with_editor(editor.move_to_end),
    [ctrl 'W'              ] = with_editor(editor.kill_prev_word),
    [meta 'd'              ] = with_editor(editor.kill_next_word),
    [ctrl 'B'              ] = with_editor(editor.move_left),
    [ctrl 'F'              ] = with_editor(editor.move_right),
    [ctrl 'Y'              ] = with_editor(editor.paste),
    [ctrl 'T'              ] = with_editor(editor.swap),
    [meta 'f'              ] = with_editor(editor.move_next_word),
    [meta 'b'              ] = with_editor(editor.move_prev_word),
    [meta 'k'              ] = with_editor(editor.hexinput),
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

-- Keys when neither an input mode nor the view handled them
M.global = {
    [0x1b] = function() -- Esc
        log.dismiss()
        editor.reset(control.editor())
        control.set_input_mode()
        local vs = control.view_state(HUB.state.ui.view)
        vs.scroll = 0
        vs.hscroll = 0
    end,

    [-ncurses.KEY_RESUME] = function() HUB.state.ui.focus = true end,
    [-ncurses.KEY_EXIT] = function() HUB.state.ui.focus = false end,

    [ctrl 'L'] = function() ncurses.clear() end,
    [ctrl 'N'] = control.next_view,
    [ctrl 'P'] = control.prev_view,

    [ctrl 'C'] = function() snowcone.raise(snowcone.SIGINT) end,
    [ctrl 'Z'] = function() snowcone.raise(snowcone.SIGTSTP) end,

    [string.byte '/'] = function()
        editor.reset(control.editor())
        control.set_input_mode 'command'
    end,
}

return M
