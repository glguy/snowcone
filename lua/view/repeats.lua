local M = {
    title = 'repeats',
    keypress = function() end,
    draw_status = function() end,
}

function M:render()
    local nick_counts, mask_counts = {}, {}
    for user, mask in users:each() do
        local nick, count = user.nick, user.count
        nick_counts[nick] = (nick_counts[nick] or 0) + 1
        mask_counts[mask] = count
    end

    local function top_keys(tab)
        local result, i = {}, 0
        for k,v in pairs(tab) do
            i = i + 1
            result[i] = {k,v}
        end
        table.sort(result, function(x,y)
            local a, b = x[2], y[2]
            if a == b then return x[1] < y[1] else return a > b end
        end)
        return result
    end

    local nicks = top_keys(nick_counts)
    local masks = top_keys(mask_counts)

    for i = 1, tty_height - 1 do
        local nick = nicks[i]
        if nick and nick[2] > 1 then
            mvaddstr(i-1, 0,
                string.format('%4d ', nick[2]))
            blue()
            addstr(string.format('%-16s', nick[1]))
            normal()
        end

        local mask = masks[i]
        if mask then
            mvaddstr(i-1, 22, string.format('%4d ', mask[2]))
            yellow()
            addstr(mask[1])
            normal()
        end
    end
    draw_global_load('cliconn', conn_tracker)
end

return M
