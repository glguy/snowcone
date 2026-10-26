-- Notifications of mentions while the terminal is unfocused (from ircc's
-- components/NotificationManager.lua and notification/).
--
-- `[notifications] module` picks a backend: bell, mac (terminal-notifier)
-- or iterm2 (ircc's names, notification.mac and so on, work too). A
-- buffer gets one notification until it is seen; viewing it with the
-- terminal focused dismisses it.
--
-- ircc's dismiss looked up the muted entry by the unfolded target and then
-- cleared it under the backend's key, so a notification could never be
-- dismissed twice. Here both use the folded target.

local chat   <const> = require 'hub.features.chat'
local common <const> = require 'hub.features.common'

local M = {}

M.name = 'notify'

-- Backend modules by name
local backends = {
    bell = 'hub.features.notify.bell',
    mac = 'hub.features.notify.mac',
    iterm2 = 'hub.features.notify.iterm2',
}

--- Make another backend module available by name. A backend has
--- notify(previous, target, nick, text) -> handle and dismiss(handle).
function M.register_backend(name, module)
    backends[name] = module
end

function M.init_state(S)
    S.features.notify = S.features.notify or {muted = {}}
end

-- The configured backend module, or nil
local function backend()
    local cfg = HUB.state.config and HUB.state.config.notifications
    local name = cfg and cfg.module
    if not name then return nil end
    name = name:gsub('^notification%.', '')
    local module = backends[name]
    if module then
        return HUB.current.gen.require(module)
    end
end

local function muted(net)
    local all = HUB.state.features.notify.muted
    local m = all[net]
    if not m then
        m = {}
        all[net] = m
    end
    return m
end

local function focused()
    local ui = HUB.state.ui
    return ui == nil or ui.focus ~= false
end

--- Notify about a message in a buffer, unless the terminal has focus.
function M.notify(net, target, nick, text)
    local impl = backend()
    if not impl or focused() then return end
    local key = chat.fold(net, target)
    local m = muted(net)
    m[key] = impl.notify(m[key], target, nick or '?', text)
end

--- Withdraw a buffer's notification once it is seen.
function M.dismiss(net, target)
    local impl = backend()
    local m = muted(net)
    local key = chat.fold(net, target)
    local handle = m[key]
    if handle == nil then return end
    m[key] = nil
    if impl and impl.dismiss then
        impl.dismiss(handle)
    end
end

function M.subscribe(sub)
    sub.on('chat.message', function(ev)
        if ev.mention and common.enabled(ev.net, 'chat') then
            local text = ev.msg[2] or ''
            M.notify(ev.net, ev.target, ev.msg.nick, text)
        end
    end)
    sub.on('net.removed', function(ev)
        HUB.state.features.notify.muted[ev.net] = nil
    end)
end

M.routes = {
    ['notify.dismiss'] = M.dismiss,
}

return M
