-- View selection and input modes, shared by the key handlers, the command
-- line and the renderer.

local chat     <const> = require 'hub.features.chat'
local common   <const> = require 'hub.features.common'
local dispatch <const> = require 'hub.runtime.dispatch'
local editor   <const> = require 'hub.ui.editor'
local irc_model <const> = require 'hub.net.irc'
local scrub    <const> = require 'hub.lib.scrub'
local task     <const> = require 'hub.runtime.task'
local traceback <const> = require 'hub.lib.traceback'
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

---@class hub.Prompt
---@field task integer the asking task's id
---@field label string
---@field net string|nil

---@class hub.InputState
---@field mode 'command'|'filter'|'talk'|'quiet'|'action'|'notice'|'password'|nil
---@field mode_before_prompt string|false|nil the mode to go back
--- to after the prompts (false for none); nil when no prompt is shown
---@field editor hub.Editor
---@field secret hub.Editor for prompts
---@field prompts hub.Prompt[] from tasks, oldest first
---@field prompt_shown any|false the task of the prompt shown, false for none
---@field filter_target string|nil what filter mode filters: a view id, or
--- 'detail' for the detail pane

---@class hub.UiState
---@field profile string
---@field view string the shown view's id
---@field views table<string, hub.ViewState> by view id
---@field input hub.InputState
---@field current_net string|nil the network chosen for net-scoped views
---@field profile_configured string|nil ui.profile from configuration, last applied
---@field detail hub.Detail|nil shown in the detail pane
---@field detail_back hub.Detail[]|nil what the detail pane showed before it
--- followed a click to what it shows, newest last, for [BACK]

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
    ui.input.prompts = ui.input.prompts or {}
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
    if HUB.state.ui.current_net ~= id then
        -- a network's views show another network's entries now: their
        -- scroll and pin mean nothing there
        for view_id, view in pairs(HUB.current.views) do
            if view.scope == 'net' then
                local vs = HUB.state.ui.views[view_id]
                if vs then
                    vs.scroll = 0
                    vs.pin = nil
                end
            end
        end
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

--- The STATUSMSG prefix ('@' or '+') lines to a network's shown buffer
--- go out with, or nil. Each buffer keeps its own, so leaving one and
--- coming back doesn't drop its lines to the whole channel.
---@param net string
---@return string|nil
function M.statusmsg(net)
    local target = M.talk_target(net)
    local vs = M.view_state 'buffer'
    local prefixes = target and vs.statusmsg and vs.statusmsg[net]
    return prefixes and prefixes[chat.fold(net, target)]
end

--- Input modes whose line goes to the shown buffer, and the command it
--- goes out as.
M.talk_modes = {talk = 'PRIVMSG', quiet = 'PRIVMSG', action = 'PRIVMSG', notice = 'NOTICE'}

--- Where a line in a talk mode stops reaching others, when the server
--- relays it to the network's shown buffer: the bytes that do, whole
--- characters of them, and how far over the line is. Nothing when it all
--- fits, or there is nowhere to send it yet.
---@param net string
---@param mode string one of talk_modes
---@param text string valid UTF-8, as the editor gives it
---@return integer|nil cut
---@return integer|nil over
function M.overflow(net, mode, text)
    local irc = HUB.state.nets[net].irc
    local target = M.talk_target(net)
    if not (irc and target) then return end
    local room = irc_model.text_room(irc, M.talk_modes[mode], (M.statusmsg(net) or '') .. target)
    if mode == 'action' then room = room - chat.action_overhead end
    room = math.max(room, 0)
    if #text <= room then return end
    local over = #text - room
    -- back to the start of a character the cut would break
    while text:byte(room + 1) & 0xC0 == 0x80 do room = room - 1 end
    return room, over
end

--- Set the STATUSMSG prefix of a network's buffer, by default the shown
--- one; nil sends to the whole target again.
---@param net string
---@param prefix string|nil
---@param target string|nil
function M.set_statusmsg(net, prefix, target)
    target = target or M.talk_target(net)
    if not target then return end
    local vs = M.view_state 'buffer'
    vs.statusmsg = vs.statusmsg or {}
    vs.statusmsg[net] = vs.statusmsg[net] or {}
    vs.statusmsg[net][chat.fold(net, target)] = prefix
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

--- Call f(...) and return what it returns; when it raises, call
--- failed(record, err) and return nothing.
---@param failed fun(record: table, err: any)
---@param record table the view or detail kind f belongs to
---@param f function
function M.attempt(failed, record, f, ...)
    local results = table.pack(xpcall(f, traceback, ...))
    if results[1] then
        return table.unpack(results, 2, results.n)
    end
    failed(record, results[2])
end

--- What a view or detail kind that failed draws in its place.
---@param name string
---@return fun(ctx: table, win: ncurses.Window)
function M.failed_render(name)
    return function(_, win)
        win:waddstr(scrub(name), ' failed; see /status. /reload tries again.\n')
    end
end

--- Disable a view that failed to draw, which would otherwise fail every
--- frame: a stand-in takes its place in this generation, so nothing else
--- needs to know, and a reload brings the view back. Reported once, last,
--- since strict mode raises.
---@param view table
---@param err any
function M.disable_view(view, err)
    local views = HUB.current.views
    if views[view.id] ~= view then return end -- disabled already this frame
    views[view.id] = {
        id = view.id,
        title = view.title,
        scope = view.scope,
        feature = view.feature,
        command = view.command,
        render = M.failed_render(view.title or view.id),
    }
    dispatch.dirty()
    dispatch.report(view.origin or ('view ' .. view.id), err)
end

--- Report a key handler's failure. A key doesn't fail again by itself, and
--- may fail for a reason that passes, so its view or kind stays.
---@param record table a view or detail kind
---@param err any
function M.key_failed(record, err)
    dispatch.report(record.origin or ('key in ' .. (record.id or record.kind)), err)
end

--- Persistent state of a view, created on first use.
--- A view's persistent state. Views keep their own fields here too.
---@class hub.ViewState
---@field scroll integer
---@field hscroll integer
---@field page integer|nil rows a page key moves, set by the renderer
---@field max_scroll integer|nil set by the renderer
---@field pin integer|nil entry number that holds a rotating log still (ui/draw.lua)
---@field filter string|nil the saved filter
---@field expanded table<string, boolean>|nil open lists (ui/fields.lua)
---@field [string] any

---@param id string
---@return hub.ViewState
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

---@return hub.Editor # the editor record for the current input mode
function M.editor()
    local input = HUB.state.ui.input
    if input.mode == 'password' then
        return input.secret
    end
    return input.editor
end

---@param mode string|nil
function M.set_input_mode(mode)
    local input = HUB.state.ui.input
    input.mode = mode
    if mode ~= 'filter' then input.filter_target = nil end
    dispatch.dirty()
end

-- Filters ============================================================

--- The filter for a view, or for the detail pane with id 'detail': what
--- is being typed in filter mode for it, else its saved filter.
---@param id string view id, or 'detail'
---@return string|nil
function M.filter(id)
    local input = HUB.state.ui.input
    if input.mode == 'filter' and (input.filter_target or HUB.state.ui.view) == id then
        local text = editor.content(input.editor)
        if text ~= '' then return text end
        return nil
    end
    if id == 'detail' then
        local detail = M.detail()
        return detail and detail.filter
    end
    return M.view_state(id).filter
end

---@param id string view id, or 'detail'
---@param pattern string|nil
function M.set_filter(id, pattern)
    if pattern == '' then pattern = nil end
    if id == 'detail' then
        local detail = M.detail()
        if detail then detail.filter = pattern end
    else
        M.view_state(id).filter = pattern
    end
    dispatch.dirty()
end

--- Start filter mode for a view, or for the detail pane ('detail').
---@param id string
function M.start_filter(id)
    HUB.state.ui.input.filter_target = id
    M.set_input_mode 'filter'
end

-- Detail pane ========================================================

--- What the detail pane shows, above the view: one record for the client,
--- drawn by the renderer for its kind (ui/details/). It doubles as the
--- pane's view state, so it keeps the scroll and whatever the renderer
--- keeps.
---@class hub.Detail: hub.ViewState
---@field kind string names the renderer
---@field net string|nil the network it is about
---@field data any what the renderer shows

--- Show something in the detail pane, replacing what it showed, with
--- nothing to go back to.
---@param kind string
---@param net string|nil
---@param data any
function M.open_detail(kind, net, data)
    HUB.state.ui.detail = {kind = kind, net = net, data = data, scroll = 0, hscroll = 0}
    HUB.state.ui.detail_back = nil
    dispatch.dirty()
end

--- Show something a click in the detail pane leads to; [BACK] returns
--- to what the pane showed, as it was left.
---@param kind string
---@param net string|nil
---@param data any
function M.follow_detail(kind, net, data)
    local ui = HUB.state.ui
    local back = ui.detail_back or {}
    if ui.detail then table.insert(back, ui.detail) end
    M.open_detail(kind, net, data)
    ui.detail_back = back[1] and back or nil
end

--- Whether the detail pane has something to go back to.
---@return boolean
function M.can_go_back()
    return HUB.state.ui.detail_back ~= nil
end

--- Show again what the detail pane showed before it followed a click.
function M.back_detail()
    local ui = HUB.state.ui
    local back = ui.detail_back
    if not back then return end
    ui.detail = table.remove(back)
    if not back[1] then ui.detail_back = nil end
    dispatch.dirty()
end

function M.close_detail()
    HUB.state.ui.detail = nil
    HUB.state.ui.detail_back = nil
    dispatch.dirty()
end

---@return hub.Detail|nil
function M.detail()
    return HUB.state.ui.detail
end

-- Prompts ============================================================

-- Drop prompts whose task is gone, then show the oldest. What was typed
-- for one prompt, kills included, never reaches another.
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
    elseif not prompt and input.mode == 'password' then
        input.mode = input.mode_before_prompt or nil
        input.mode_before_prompt = nil
    end
    local shown = prompt and prompt.task or false
    if input.prompt_shown ~= shown then
        input.prompt_shown = shown
        editor.forget(input.secret)
    end
    dispatch.dirty()
end

---@return hub.Prompt|nil # the prompt being answered
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
    editor.forget(input.secret)
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
    ['ui.set_current_net'] = M.set_current_net,
}

return M
