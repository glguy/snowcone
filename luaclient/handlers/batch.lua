local M = {}

M['soju.im/bouncer-networks'] = function(_, messages)
    local networks = {}
    for _, irc in ipairs(messages) do
        networks[irc[2]] = snowcone.parse_irc_tags(irc[3])
    end
    irc_state.bouncer_networks = networks
end

return M
