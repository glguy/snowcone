local OrderedMap  = require_ 'components.OrderedMap'
local send = require 'utils.send'
local Task = require 'components.Task'
local N = require 'utils.numerics'
local Set = require 'pl.Set'

return function(arg)
    Task('channel list', irc_state.tasks, function(self)
        if arg then
            send('LIST', arg)
        else
            send('LIST')
        end
        channel_list = OrderedMap(10000) -- reset client channel list buffer
        local list_commands = Set{N.RPL_LISTSTART, N.RPL_LIST, N.RPL_LISTEND}
        while true do
            local irc = self:wait_irc(list_commands)
            -- "<client> <channel> <client count> :<topic>"
            if N.RPL_LIST == irc.command then
                local channel = irc[2]
                channel_list:insert(channel, {
                    time = os.date("!%H:%M:%S"),
                    timestamp = uptime,
                    channel = channel,
                    users = math.tointeger(irc[3]),
                    topic = irc[4],
                })

            -- "<client> :End of /LIST"
            elseif N.RPL_LISTEND == irc.command then
                return
            
                -- "<client> :Start of /LIST"
            elseif N.RPL_LISTSTART == irc.command then
                -- some servers don't send this
                list_commands[N.RPL_LISTSTART] = nil
            end
        end
    end)
end
