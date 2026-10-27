-- View selection and input modes, shared by the key handlers, the command
-- line and the renderer.

local common   <const> = require 'hub.features.common'
local dispatch <const> = require 'hub.runtime.dispatch'
local editor   <const> = require 'hub.ui.editor'
local task     <const> = require 'hub.runtime.task'
local manager  <const> = require 'hub.net.manager'

local M = {}

-- Main view rotation for Ctrl-N/Ctrl-P per profile. Views that aren't
-- loaded, or need a feature the current network lacks, are skipped.
M.profiles = {
    dashboard = {
        'cliconn', 'connload', 'cliexit', 'exitload', 'bans', 'channels', 'netcount',
        'console', 'networks', 'status',
    },
    chat = {'buffer', 'console', 'networks', 'status'},
    all = {
        'cliconn', 'connload', 'cliexit', 'exitload', 'bans', 'channels', 'netcount',
        'console', 'buffer', 'networks', 'status',
    },
}

function M.init_state(S)
    local ui = S.ui or {}
    S.ui = ui
    ui.profile = ui.profile or 'all'
    ui.view = ui.view or 'status'
    ui.views = ui.views or {}
    ui.input = ui.input or {}
    ui.input.editor = ui.input.editor or editor.new()
    -- Secrets get their own editor: a half-typed command survives a prompt,
    -- and nothing typed here reaches the history
    ui.input.secret = ui.input.secret or editor.new()
    -- Prompts from tasks, oldest first: {task = id, label = string, net = id}
    ui.input.prompts = ui.input.prompts or {}
    -- input.mode: nil, 'command', 'filter', 'talk' or 'password'
    if ui.focus == nil then ui.focus = true end
end

-- Networks ===========================================================

--- Network ids in configuration order.
M.net_ids = manager.ids

--- The network that net-scoped views and commands act on: the chosen one
--- if it still exists, else the first configured.
---@return string|nil
function M.current_net()
    local nets = HUB.state.nets or {}
    local id = HUB.state.ui.current_net
    if id and nets[id] then return id end
    local first = manager.ids()[1]
    HUB.state.ui.current_net = first
    return first
end

function M.set_current_net(id)
    if not HUB.state.nets[id] then
        error('no such network: ' .. tostring(id), 0)
    end
    HUB.state.ui.current_net = id
    M.ensure_usable_view()
    dispatch.dirty()
end

-- Talk targets =======================================================

--- The buffer shown for a network, by name.
function M.talk_target(net)
    local vs = M.view_state 'buffer'
    return vs.targets and vs.targets[net]
end

--- Show a buffer of a network, remembering the one shown before.
function M.set_talk_target(net, target)
    local vs = M.view_state 'buffer'
    vs.targets = vs.targets or {}
    vs.previous = vs.previous or {}
    local current = vs.targets[net]
    if current ~= target then
        vs.previous[net] = current
        vs.targets[net] = target
        vs.scroll = 0
    end
    dispatch.dirty()
end

-- Configuration ======================================================

--- Follow ui.profile from configuration when it changes; /profile can
--- override it until the configured value changes again.
function M.apply_config(cfg)
    local ui = HUB.state.ui
    local profile = cfg.ui and cfg.ui.profile or 'all'
    if ui.profile_configured ~= profile then
        ui.profile_configured = profile
        ui.profile = profile
    end
end

--- Whether a view can show anything for a network: a view with a
--- `feature` needs the network to have it.
function M.usable(view, net)
    return view.feature == nil or net ~= nil and common.enabled(net, view.feature)
end

--- The views of the current profile's rotation that exist and that the
--- current network has the features for, for Ctrl-N/Ctrl-P and the
--- function keys (which renumber with the network).
---@return string[]
function M.rotation()
    local views, net = HUB.current.views, M.current_net()
    local order = {}
    for _, id in ipairs(M.profiles[HUB.state.ui.profile] or M.profiles.all) do
        local view = views[id]
        if view and M.usable(view, net) then
            table.insert(order, id)
        end
    end
    return order
end

--- The view to open with: the first of the rotation for a feature the
--- current network has (cliconn with server notices, buffer with only
--- chat), else the first that needs no feature.
function M.first_view()
    local views = HUB.current.views
    local general
    for _, id in ipairs(M.rotation()) do
        if views[id].feature then return id end
        general = general or id
    end
    return general or 'status'
end

--- Move to the first view when the current one needs a feature the
--- current network lacks, as after switching networks or a reload that
--- changed a network's features.
function M.ensure_usable_view()
    local view = HUB.current.views[HUB.state.ui.view]
    if view and not M.usable(view, M.current_net()) then
        M.set_view(M.first_view())
    end
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

---@return table the editor record for the current input mode
function M.editor()
    local input = HUB.state.ui.input
    if input.mode == 'password' then
        return input.secret
    end
    return input.editor
end

---@param mode string|nil
function M.set_input_mode(mode)
    HUB.state.ui.input.mode = mode
    dispatch.dirty()
end

-- Filters ============================================================

--- The filter for a view: what is being typed in filter mode, else the
--- view's saved filter.
---@return string|nil
function M.filter(id)
    local input = HUB.state.ui.input
    if input.mode == 'filter' and HUB.state.ui.view == id then
        local text = editor.content(input.editor)
        if text ~= '' then return text end
        return nil
    end
    return M.view_state(id).filter
end

function M.set_filter(id, pattern)
    if pattern == '' then pattern = nil end
    M.view_state(id).filter = pattern
    dispatch.dirty()
end

-- Prompts ============================================================

-- Drop prompts whose task is gone, then show the oldest
local function next_prompt()
    local input = HUB.state.ui.input
    local prompts = input.prompts
    while prompts[1] and not HUB.tasks[prompts[1].task] do
        table.remove(prompts, 1)
    end
    local prompt = prompts[1]
    if prompt and input.mode ~= 'password' then
        input.mode_before_prompt = input.mode or false
        input.mode = 'password'
        editor.reset(input.secret)
    elseif not prompt and input.mode == 'password' then
        input.mode = input.mode_before_prompt or nil
        input.mode_before_prompt = nil
    end
    dispatch.dirty()
end

---@return table|nil the prompt being answered
function M.current_prompt()
    local input = HUB.state.ui.input
    if input.mode == 'password' then
        return input.prompts[1]
    end
end

--- Queue a prompt from the task.prompt event.
function M.add_prompt(ev)
    table.insert(HUB.state.ui.input.prompts, {task = ev.task, label = ev.label, net = ev.net})
    next_prompt()
end

--- Answer the current prompt; nil aborts it.
function M.answer_prompt(text)
    local input = HUB.state.ui.input
    local prompt = table.remove(input.prompts, 1)
    editor.reset(input.secret)
    input.mode = input.mode_before_prompt or nil
    input.mode_before_prompt = nil
    if prompt then
        task.answer(prompt.task, text)
    end
    next_prompt()
end

--- Show the next prompt if one is waiting.
M.check_prompts = next_prompt

M.routes = {
    ['ui.show_view'] = M.set_view,
    ['ui.set_current_net'] = M.set_current_net,
}

return M
