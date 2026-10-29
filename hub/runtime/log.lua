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

M.capacity = 1000

function M.init_state(S)
    S.log = S.log or OrderedMap.new(M.capacity)
    -- last line, shown in the status bar until dismissed
    if S.log_last == nil then S.log_last = false end
end

local function add(net, category, fmt, ...)
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
    add(nil, category, fmt, ...)
end

--- Add a line about a network to the log.
---@param net string|nil network id
---@param category string
---@param fmt string format string, or the text when no arguments follow
---@param ... any format arguments
function M.add_net(net, category, fmt, ...)
    add(net, category, fmt, ...)
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

--- Log the lines of an error after its first, which hold its traceback.
function M.trace(err)
    for line in tostring(err):gmatch '\n([^\n]*)' do
        M.add('trace', '%s', (line:gsub('^\t', '  ')))
    end
end

--- Log an error, keeping the traceback lines out of the status bar.
function M.error(where, err)
    M.count_error(where)
    err = tostring(err)
    local first = err:match '^[^\n]*'
    M.add('error', '%s: %s', where, first)
    M.trace(err)
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
