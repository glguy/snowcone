-- An error in the detail pane: where it came from, its whole message, and
-- the traceback of an error from code (log.error_data).

local draw  <const> = require 'hub.ui.draw'
local scrub <const> = require 'hub.lib.scrub'

local M = {kind = 'error'}

function M.title(detail)
    return 'error ' .. scrub(detail.data.where)
end

function M.render(ctx, win)
    local data = ctx.vs.data

    draw.red(win)
    draw.bold(win)
    for line in (data.message .. '\n'):gmatch '([^\n]*)\n' do
        win:waddstr(scrub(line), '\n')
    end
    draw.normal(win)

    if data.traceback then
        for line in (data.traceback .. '\n'):gmatch '([^\n]*)\n' do
            -- the frames, under their heading
            if line:sub(1, 1) == '\t' then
                draw.normal(win)
                win:waddstr('  ', scrub(line:sub(2)), '\n')
            else
                draw.blue(win)
                win:waddstr(scrub(line), '\n')
            end
        end
        draw.normal(win)
    end
end

return M
