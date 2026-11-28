-- The accept list (user mode +g, caller ID): accept.fetch(net) asks for
-- it with ACCEPT *, as a network task. The nicks that may message us past
-- +g are gathered into a hub.AcceptList, logged as one line that opens it,
-- and emitted as query.accept for the UI to show.
--
-- The list is a snapshot: the server drops a nick from it when that user
-- quits, or changes nick sharing no channel with us, and the whole list
-- when we disconnect from it; through a bouncer, it lasts as long as the
-- bouncer's connection. Solanum sends up to 15 nicks a reply, each an
-- argument; OFTC hybrid fills the last argument with as many as fit.
--
-- Without labeled-response nothing tells one ACCEPT *'s reply from
-- another's, so a network has one fetch at a time: a fetch asked for
-- while one runs is made once that one is done. OFTC hybrid also sends
-- the list, unasked, after each nick it adds, so adding several at once
-- shows the list as it was after the first until it is fetched again.

local common <const> = require 'hub.features.common'
local bus    <const> = require 'hub.runtime.bus'
local log    <const> = require 'hub.runtime.log'
local N      <const> = require 'hub.lib.numerics'
local task   <const> = require 'hub.runtime.task'

local M = {}

M.name = 'accept'

--- The accept list as the server sent it.
---@class hub.AcceptList
---@field nicks string[] in the server's order
---@field at integer epoch seconds when the list came

--- A network's fetches, state.features.accept[net].
---@class hub.AcceptState
---@field again boolean a fetch was asked for while one ran

local commands <const> = {
    [N.RPL_ACCEPTLIST] = true, [N.RPL_ENDOFACCEPT] = true, [N.ERR_UNKNOWNCOMMAND] = true,
}

---@return hub.AcceptState
local function get(net)
    return common.net_state(M.name, net, function() return {again = false} end)
end

-- One ACCEPT *, shown once it ends; false when it fails
---@param t hub.Task
local function once(t)
    ---@type hub.AcceptList
    local list = {nicks = {}, at = os.time()}
    for msg in t:request(commands, 30000, 'ACCEPT', '*') do
        if msg.command == N.RPL_ACCEPTLIST then
            -- every argument after our nick
            for i = 2, #msg do
                for nick in msg[i]:gmatch '%S+' do table.insert(list.nicks, nick) end
            end
        elseif msg.command == N.RPL_ENDOFACCEPT then
            list.at = os.time()
            local n = #list.nicks
            log.add_detail(t.net, M.name, {kind = 'accept', data = list}, 'accept list: %d %s', n,
                n == 1 and 'nick' or 'nicks')
            bus.emit('query.accept', {net = t.net, accept = list})
            return true
        elseif msg[2] == 'ACCEPT' then
            t:log(M.name, 'ACCEPT: %s', msg[#msg] or 'unknown command')
            return false
        end
    end
    t:log(M.name, 'ACCEPT *: no reply')
    return false
end

-- Fetch until no other fetch was asked for meanwhile
---@param t hub.Task
local function run(t)
    local S = get(t.net)
    repeat
        S.again = false
    until not (once(t) and S.again)
end

--- Ask for the network's accept list, to show; while a fetch runs, again
--- once it is done.
---@param net string
function M.fetch(net)
    for _, t in pairs(HUB.tasks) do
        if t.name == M.name and t.net == net then
            get(net).again = true
            return
        end
    end
    task.spawn(M.name, {net = net, owner = 'queries'}, run)
end

--- Forget a removed network's fetches.
---@param net string
function M.drop(net)
    common.drop_state(M.name, net)
end

return M
