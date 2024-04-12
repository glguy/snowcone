-- Global keyboard mapping - can be overriden by views
local M = {
    --[[Esc]][0x1b] = function()
        reset_filter()
        status_message = nil
        editor:reset()
        input_mode = nil
        scroll = 0
        hscroll = 0
    end,

    [-ncurses.KEY_RESUME] = function()
        terminal_focus = true
    end,

    [-ncurses.KEY_EXIT] = function()
        terminal_focus = false
    end,

    [ctrl 'L'] = function() ncurses.clear() end,
    [ctrl 'N'] = next_view,
    [ctrl 'P'] = prev_view,

    [ctrl 'C'] = function() snowcone.raise(snowcone.SIGINT) end,
    [ctrl 'Z'] = function() snowcone.raise(snowcone.SIGTSTP) end,

    [ctrl 'S'] = function()
        editor:reset()
        input_mode = 'filter'
    end,
    [string.byte('/')] = function()
        editor:reset()
        input_mode = 'command'
    end,

    -- jump to next /talk activity (alphabetically)
    [meta 'a'] = function()
        local current = talk_target or ''

        local best_target
        local best_mention

        for k, buffer in pairs(buffers) do
            if buffer.messages.n > buffer.seen then
                -- jump to next window alphabetically preferring mentions
                if not best_target
                or buffer.mention and not best_mention
                or buffer.mention == best_mention
                and (best_target < current and current < k
                  or (current < best_target) == (current < k) and k < best_target)
                then
                    best_target = k
                    best_mention = buffer.mention
                end
            end
        end

        if best_target then
            set_talk_target(best_target)
            set_view 'buffer'
        end
    end,

    [meta 's'] = function()
        if view == 'buffer' then
            talk_target_old, talk_target = talk_target, talk_target_old
        elseif talk_target then
            set_view 'buffer'
        end
    end,

    [-ncurses.KEY_RIGHT] = function()
        local scroll_unit = math.max(1, tty_width - 26)
        hscroll = math.max(0, math.min(550 - tty_width, hscroll + scroll_unit))
    end,
    [-ncurses.KEY_LEFT] = function()
        local scroll_unit = math.max(1, tty_width - 26)
        hscroll = math.max(0, hscroll - scroll_unit)
    end,
}

for i, v in ipairs(main_views) do
    M[-(ncurses.KEY_F1 - 1 + i)] = function() set_view(v) end
end

return M
