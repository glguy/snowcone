-- IRCv3 batches (from ircc's BATCH handler and handlers/batch.lua).
--
-- Messages tagged with an open batch are collected instead of handled one
-- by one. When the batch closes, protocol-level types update the model and
-- every batch is emitted as `irc.batch`.

local bus <const> = require 'hub.runtime.bus'

local M = {}

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
---@return boolean true if the message belonged to a batch
function M.collect(irc, msg)
    local batch = irc.batches[msg.tags.batch]
    if batch then
        local n = batch.n + 1
        batch.n = n
        batch.messages[n] = msg
        return true
    end
    return false
end

--- Handle a BATCH command.
function M.BATCH(net, irc, msg)
    local polarity = msg[1]:sub(1, 1)
    local name = msg[1]:sub(2)

    if '+' == polarity then
        irc.batches[name] = {
            type = msg[2],
            params = table.move(msg, 3, #msg, 1, {}),
            messages = {},
            n = 0,
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
