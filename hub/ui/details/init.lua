-- The renderers of the detail pane, by kind, and where the filter goes.
--
-- A renderer is {kind, render(ctx, win), title(detail), modes(detail),
-- keypress(ctx, key), filter}; ctx.vs is the detail record. One with
-- `filter` set takes the filter (Ctrl-S, /filter) while it is shown, and
-- reads it with control.filter(ctx.id), as a view does.

local control <const> = require 'hub.ui.control'

local M = {}

---@type table<string, table>
M.kinds = {}
for _, m in ipairs {
    require 'hub.ui.details.error',
    require 'hub.ui.details.keys',
    require 'hub.ui.details.message',
    require 'hub.ui.details.reply',
    require 'hub.ui.details.value',
    require 'hub.ui.details.whois',
    require 'hub.ui.details.whowas',
} do
    M.kinds[m.kind] = m
end

--- What a filter applies to now: 'detail' while the pane shows a kind
--- that filters, else the current view's id.
---@return string
function M.filter_target()
    local detail = control.detail()
    local kind = detail and M.kinds[detail.kind]
    if kind and kind.filter then return 'detail' end
    return HUB.state.ui.view
end

return M
