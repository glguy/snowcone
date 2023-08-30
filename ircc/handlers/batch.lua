local split_statusmsg = require 'utils.split_statusmsg'
local M = {}

-- Populate the bouncer_networks information with
M['soju.im/bouncer-networks'] = function(_, messages)
    local networks = {}
    for _, irc in ipairs(messages) do
        -- BOUNCER NETWORK <netid> <tag-encoded attributes>
        if 'BOUNCER' == irc.command and 'NETWORK' == irc[1] then
            networks[irc[2]] = snowcone.parse_irc_tags(irc[3])
        end
    end
    irc_state.bouncer_networks = networks
end

-- If a chathistory batch corresponds to an active buffer
-- route the chat messages to it.
M['chathistory'] = function(params, messages)
    local target = params[1]
    local buffer = buffers[snowcone.irccase(target)]
    if not buffer then return end

    for _, irc in ipairs(messages) do
        local command = irc.command
        if command == "PRIVMSG" or command == "NOTICE" then
            local prefix = split_statusmsg(irc[1])
            irc.statusmsg = prefix
            buffer.messages:insert(true, irc)
        end
    end
end

return M
