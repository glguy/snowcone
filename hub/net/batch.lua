-- IRCv3 batches (from ircc's BATCH handler and handlers/batch.lua).
--
-- Messages tagged with an open batch are collected, and when the batch
-- closes it is emitted whole as `irc.batch`. Most batches (a netsplit's
-- QUITs, say) are also handled message by message as they arrive, so the
-- protocol model stays current. A replay batch (chat history) is not: it
-- tells of the past and must not change the connection's state, so its
-- messages reach only `irc.batch`, for the chat buffers. A batch nested in
-- a replay is a replay too.

local bus <const> = require 'hub.runtime.bus'

local M = {}

--- Batch types that replay the past
M.replay_types = {
    ['chathistory'] = true,
    ['draft/chathistory-targets'] = true,
}

-- Batch types the protocol model consumes
local consumers = {}

consumers['soju.im/bouncer-networks'] = function(irc, _, messages)
    local networks = {}
    for _, msg in ipairs(messages) do
        -- BOUNCER NETWORK <netid> <tag-encoded attributes>
        if 'BOUNCER' == msg.command and 'NETWORK' == msg[1] then
            networks[msg[2]] = snowcone.parse_irc_tags(msg[3])
        end
    end
    irc.bouncer_networks = networks
end

--- Collect a message into its open batch.
---@return table|nil the batch the message belongs to
function M.collect(irc, msg)
    local batch = irc.batches[msg.tags.batch]
    if batch then
        local n = batch.n + 1
        batch.n = n
        batch.messages[n] = msg
    end
    return batch
end

--- Handle a BATCH command.
function M.BATCH(net, irc, msg)
    local polarity = msg[1]:sub(1, 1)
    local name = msg[1]:sub(2)

    if '+' == polarity then
        local parent = irc.batches[msg.tags.batch]
        irc.batches[name] = {
            type = msg[2],
            params = table.move(msg, 3, #msg, 1, {}),
            messages = {},
            n = 0,
            replay = M.replay_types[msg[2]] or (parent ~= nil and parent.replay),
        }
    elseif '-' == polarity then
        local batch = irc.batches[name]
        irc.batches[name] = nil
        if batch then
            local consume = consumers[batch.type]
            if consume then
                consume(irc, batch.params, batch.messages)
            end
            bus.emit('irc.batch', {
                net = net,
                type = batch.type,
                params = batch.params,
                messages = batch.messages,
            })
        end
    end
end

return M
