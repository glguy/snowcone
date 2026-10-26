-- Routes and trampolines.
--
-- Native code keeps every callback it is given, across reloads. Each one is
-- a trampoline that looks up its route in HUB.current when it runs, so it
-- always calls the current generation's code. It also catches errors: the
-- client reports an uncaught error by leaving curses mode, so they are
-- logged here instead.

local scrub <const> = require 'hub.lib.scrub'

local M = {}

--- Report an error raised by a route.
---@param where string route or other description
---@param err string message with traceback
function M.report(where, err)
    local current = HUB.current
    local report = current and current.routes['log.error']
    if report then
        report(where, err)
    else
        -- line by line, so the traceback keeps its shape
        io.stderr:write(scrub(where), ': ', (string.gsub(tostring(err), '[^\n]+', scrub)), '\n')
    end
    if HUB.boot and HUB.boot.strict then
        error(err, 0)
    end
end

--- Look up a route in the current generation.
---@param route string
---@return function
function M.route(route)
    local f = HUB.current.routes[route]
    if f == nil then
        error('no such route: ' .. route, 2)
    end
    return f
end

--- Draw when something changed and nothing holds drawing back.
function M.flush()
    if HUB.defer_draw then
        HUB.defer_draw = false
        return
    end
    local current = HUB.current
    -- shutdown restored the terminal; drawing would take it back
    if HUB.shut_down then return end
    if HUB.dirty and current then
        local draw = current.routes['ui.draw']
        if draw then
            HUB.dirty = false
            local ok, err = xpcall(draw, debug.traceback)
            if not ok then M.report('ui.draw', err) end
        else
            HUB.dirty = false
        end
    end
end

--- Mark the screen as needing a redraw at the end of this native callback.
function M.dirty()
    HUB.dirty = true
end

--- Skip the draw at the end of the current native callback. The screen
--- stays dirty, so the next callback that doesn't defer draws it. The
--- connection callback defers for every MSG whose flush flag is false, so a
--- burst of lines from one read draws once.
function M.defer_draw()
    HUB.defer_draw = true
end

--- Call a route as an entry point from native code.
function M.enter(route, ...)
    local ok, err = xpcall(M.route, debug.traceback, route)
    if ok then
        ok, err = xpcall(err, debug.traceback, ...)
    end
    if not ok then M.report(route, err) end
    M.flush()
end

--- Make a callback for native code.
---
--- Bound arguments are passed before the callback's own and MUST be plain
--- data (ids, numbers, strings): they outlive the generation that bound them.
---@param route string
---@return function
function M.trampoline(route, ...)
    -- The closure must not capture anything from this module: it outlives
    -- the generation, and the current entry point is found through HUB.
    local bound = table.pack(...)
    if bound.n == 0 then
        return function(...)
            HUB.current.routes['dispatch.enter'](route, ...)
        end
    end
    return function(...)
        local args = table.pack(...)
        local all = table.move(bound, 1, bound.n, 1, {})
        table.move(args, 1, args.n, bound.n + 1, all)
        HUB.current.routes['dispatch.enter'](route, table.unpack(all, 1, bound.n + args.n))
    end
end

M.routes = {
    ['dispatch.enter'] = M.enter,
}

--- Install the single native entry point; it never needs replacing.
function M.install_entry()
    if not HUB.entry_installed then
        HUB.entry_installed = true
        snowcone.setmodule(M.trampoline 'ui.entry')
        -- SIGINT, SIGTERM and SIGHUP arrive as on_signal until shutdown
        snowcone.catch_signals(true)
    end
end

return M
