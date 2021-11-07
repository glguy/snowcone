local M = {}

function M.fade_time(timestamp, time)
    local age = uptime - timestamp
    if age < 8 then
        white()
        addstr(string.sub(time, 1, 8-age))
        cyan()
        addstr(string.sub(time, 9-age, 8))
    else
        cyan()
        addstr(time)
    end
end

function M.add_population(pop)
    if pop then
        if pop < 1000 then
            addstr(string.format('  %5d', pop))
        else
            bold()
            addstr(string.format('  %2d', pop // 1000))
            bold_()
            addstr(string.format('%03d', pop % 1000))
        end
    else
        addstr('      ?')
    end
end

local function draw_load_1(avg, i)
    if avg.n >= 60*i then
        bold()
        addstr(string.format('%5.2f ', avg[i]))
        bold_()
    else
        addstr(string.format('%5.2f ', avg[i]))
    end
end

function M.draw_load(avg)
    draw_load_1(avg, 1)
    draw_load_1(avg, 5)
    draw_load_1(avg,15)
    addstr('[')
    underline()
    addstr(avg:graph())
    underline_()
    addstr(']')
end

return M