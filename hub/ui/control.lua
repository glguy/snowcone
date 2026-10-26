-- View selection and input modes, shared by the key handlers, the command
-- line and the renderer.

local dispatch <const> = require 'hub.runtime.dispatch'
local editor   <const> = require 'hub.ui.editor'

local M = {}

-- Main view rotation for Ctrl-N/Ctrl-P per profile (design section 8.3).
-- Views that aren't loaded are skipped.
M.profiles = {
    dashboard = {'cliconn', 'connload', 'cliexit', 'exitload', 'bans', 'channels', 'netcount', 'console', 'status'},
    chat = {'buffer', 'console', 'status'},
    all = {'cliconn', 'connload', 'cliexit', 'exitload', 'bans', 'channels', 'netcount', 'console', 'buffer', 'status'},
}

function M.init_state(S)
    local ui = S.ui or {}
    S.ui = ui
    ui.profile = ui.profile or 'all'
    ui.view = ui.view or 'status'
    ui.views = ui.views or {}
    ui.input = ui.input or {}
    ui.input.editor = ui.input.editor or editor.new()
    -- input.mode: nil, 'command', 'filter', 'talk' or 'password'
    if ui.focus == nil then ui.focus = true end
end

--- The views in the current profile's rotation that exist.
---@return string[]
function M.rotation()
    local views = HUB.current.views
    local order = {}
    for _, id in ipairs(M.profiles[HUB.state.ui.profile] or M.profiles.all) do
        if views[id] then
            table.insert(order, id)
        end
    end
    return order
end

--- The current view record, falling back to status when it is missing
--- (for example after a reload that dropped the view).
function M.current_view()
    local views = HUB.current.views
    return views[HUB.state.ui.view] or views.status
end

--- Persistent state of a view, created on first use.
---@param id string
---@return table
function M.view_state(id)
    local views = HUB.state.ui.views
    local vs = views[id]
    if vs == nil then
        vs = {scroll = 0, hscroll = 0}
        views[id] = vs
    end
    return vs
end

function M.set_view(id)
    local ui = HUB.state.ui
    if ui.view ~= id then
        ui.view = id
        local vs = M.view_state(id)
        vs.scroll = 0
        vs.hscroll = 0
    end
    dispatch.dirty()
end

local function step_view(delta)
    local order = M.rotation()
    if #order == 0 then return end
    local current
    for i, id in ipairs(order) do
        if id == HUB.state.ui.view then current = i end
    end
    if current then
        M.set_view(order[(current - 1 + delta) % #order + 1])
    else
        M.set_view(order[1])
    end
end

function M.next_view() step_view(1) end
function M.prev_view() step_view(-1) end

---@return table the editor record
function M.editor()
    return HUB.state.ui.input.editor
end

---@param mode string|nil
function M.set_input_mode(mode)
    HUB.state.ui.input.mode = mode
    dispatch.dirty()
end

M.routes = {
    ['ui.show_view'] = M.set_view,
}

return M
