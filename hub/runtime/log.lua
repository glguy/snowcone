-- Status log. It also receives the client's print().

local bus        <const> = require 'hub.runtime.bus'
local clock      <const> = require 'hub.runtime.clock'
local dispatch   <const> = require 'hub.runtime.dispatch'
local OrderedMap <const> = require 'hub.lib.OrderedMap'

local M = {}

---@class hub.LogEntry
---@field time string HH:MM:SS
---@field timestamp number
---@field category string
---@field text string
---@field net string|nil
---@field detail hub.LogDetail|nil

--- What a log line can open in the UI's detail pane: data for the
--- renderer of its kind (ui/details/).
---@class hub.LogDetail
---@field kind string
---@field data any

M.capacity = 1000

function M.init_state(S)
    S.log = S.log or OrderedMap.new(M.capacity)
    -- last line, shown in the status bar until dismissed
    if S.log_last == nil then S.log_last = false end
end

local function add(net, category, detail, fmt, ...)
    local text = select('#', ...) == 0 and fmt or string.format(fmt, ...)
    local S = HUB.state

    if S == nil or S.log == nil then
        io.stderr:write(category, ': ', text, '\n')
        return
    end

    local entry = {
        time = os.date '!%H:%M:%S',
        timestamp = clock.now(),
        category = category,
        text = text,
        net = net,
        detail = detail,
    }
    OrderedMap.insert(S.log, nil, entry)
    S.log_last = net and (net .. ': ' .. text) or text

    if HUB.boot and HUB.boot.echo then
        if net then
            print(string.format('[%s] %s: %s', category, net, text))
        else
            print(string.format('[%s] %s', category, text))
        end
    end

    bus.emit('log', entry)
    dispatch.dirty()
end

--- Add a line to the log.
---@param category string
---@param fmt string format string, or the text when no arguments follow
---@param ... any format arguments
function M.add(category, fmt, ...)
    add(nil, category, nil, fmt, ...)
end

--- Add a line about a network to the log.
---@param net string|nil network id
---@param category string
---@param fmt string format string, or the text when no arguments follow
---@param ... any format arguments
function M.add_net(net, category, fmt, ...)
    add(net, category, nil, fmt, ...)
end

--- Add a line that summarizes something the UI can show in full.
---@param net string|nil network id
---@param category string
---@param detail hub.LogDetail
---@param fmt string format string, or the text when no arguments follow
---@param ... any format arguments
function M.add_detail(net, category, detail, fmt, ...)
    add(net, category, detail, fmt, ...)
end

--- Whether a line of the log holds a detail with this data.
function M.holds_detail(data)
    for entry in OrderedMap.each(HUB.state.log) do
        if entry.detail and entry.detail.data == data then return true end
    end
    return false
end

--- Drop the detail with this data from every line that holds it; the
--- lines stay.
function M.forget_detail(data)
    for entry in OrderedMap.each(HUB.state.log) do
        if entry.detail and entry.detail.data == data then entry.detail = nil end
    end
    dispatch.dirty()
end

--- Clear the status bar's copy of the last line.
function M.dismiss()
    HUB.state.log_last = false
end

--- Count an error by where it came from (a route, a subscriber, a
--- command, a plugin), for /stats. The counts live in HUB, outside state.
function M.count_error(where)
    local errors = HUB.errors or {total = 0, by_origin = {}}
    HUB.errors = errors
    errors.total = errors.total + 1
    errors.by_origin[where] = (errors.by_origin[where] or 0) + 1
end

--- An error for the detail pane (ui/details/error.lua): where it came
--- from, its message, and the traceback an error from code carries. nil
--- for a one-line error, as one raised for the user at level 0 is.
---@param where string
---@param err any
---@return {where: string, message: string, traceback: string|nil}|nil
function M.error_data(where, err)
    err = tostring(err)
    if not err:find '\n' then return nil end
    local message, traceback = err:match '^(.-)\n(stack traceback:\n.*)$'
    return {where = where, message = message or err, traceback = traceback}
end

--- Log the first line of an error, with the rest in the line's detail.
---@param category string
---@param where string
---@param err any
---@param fmt string format string for the line
---@param ... any format arguments
function M.add_error(category, where, err, fmt, ...)
    local data = M.error_data(where, err)
    add(nil, category, data and {kind = 'error', data = data}, fmt, ...)
end

--- Log an error as one line, keeping its traceback out of the log and the
--- status bar: it is in the line's detail.
function M.error(where, err)
    M.count_error(where)
    err = tostring(err)
    local first = err:match '^[^\n]*'
    M.add_error('error', where, err, '%s: %s', where, first)
    local S = HUB.state
    if S and S.log then
        S.log_last = string.format('%s: %s', where, first)
    end
end

M.routes = {
    ['log.add'] = M.add,
    ['log.error'] = M.error,
    ['log.print'] = function(text) M.add('print', '%s', text) end,
}

return M
