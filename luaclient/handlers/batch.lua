local M = {}

M['soju.im/bouncer-networks'] = function(_, messages)
    local networks = {}
    for _, irc in ipairs(messages) do
        networks[irc[2]] = snowcone.parse_irc_tags(irc[3])
    end
    irc_state.bouncer_networks = networks
end

M['chathistory'] = function(params, messages)
    local target = params[1]
    local buffer = buffers[target]
    if not buffer then return end

    for _, irc in ipairs(messages) do
        local command = irc.command
        if command == "PRIVMSG" or command == "NOTICE" then
            buffer:insert(true, irc)
        end
    end
end

return M
