-- Server notices (design section 7.1): recognise them on networks with the
-- snotice feature, parse them, update the stores and emit `snote` and
-- `snote.<name>` with the network id.

local bus    <const> = require 'hub.runtime.bus'
local common <const> = require 'hub.features.common'
local parse  <const> = require 'hub.features.snotice.parse'
local stores <const> = require 'hub.features.snotice.stores'

local M = {}

M.name = 'snotice'

local header <const> = '*** Notice -- '

--- The text of a server notice, without its header, or nil. A server
--- notice is a NOTICE to * from a server (no ! or @ in the source).
---@param msg table
---@return string|nil
function M.notice_text(msg)
    local source = msg.source
    if msg.command == 'NOTICE' and msg[1] == '*' and #msg == 2
    and source and not source:find '[!@]'
    and msg[2]:sub(1, #header) == header then
        return msg[2]:sub(#header + 1)
    end
end

--- Parse a message into a notice event for a network, or nil.
function M.parse(net, msg)
    local text = M.notice_text(msg)
    if not text then return nil end
    local ev = parse(msg.time, msg.source, text)
    if ev then
        ev.net = net
        ev.timestamp = msg.timestamp
    end
    return ev
end

local function on_message(ev)
    if not common.enabled(ev.net, M.name) then return end
    local note = M.parse(ev.net, ev.msg)
    if note then
        stores.apply(note)
        bus.emit('snote', note)
        bus.emit('snote.' .. note.name, note)
    end
end

function M.subscribe(sub)
    sub.on('irc.message', on_message)
    sub.on('clock.tick', stores.tick)
    sub.on('net.removed', function(ev) common.drop_state(M.name, ev.net) end)
end

return M
