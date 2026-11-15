-- Errors about a channel, by numeric: which parameter names the
-- channel. A JOIN refused, or a change we asked for there, is shown in
-- the channel's buffer, which would otherwise show nothing happened.
-- Chat routes them (features/chat), and the hide rules' check knows them
-- as commands a buffer can hold (runtime/config.lua).

local N <const> = require 'hub.lib.numerics'

return {
    [N.ERR_NOSUCHCHANNEL] = 2,      -- <channel> :reason
    [N.ERR_TOOMANYCHANNELS] = 2,
    [N.ERR_BANNICKCHANGE] = 3,      -- <nick> <channel> :reason
    [N.ERR_UNAVAILRESOURCE] = 2,    -- a channel juped, or a nick
    [N.ERR_USERNOTINCHANNEL] = 3,   -- <nick> <channel> :reason
    [N.ERR_NOTONCHANNEL] = 2,
    [N.ERR_LINKCHANNEL] = 2,        -- <channel> <forward> :reason
    [N.ERR_CHANNELISFULL] = 2,
    [N.ERR_INVITEONLYCHAN] = 2,
    [N.ERR_BANNEDFROMCHAN] = 2,
    [N.ERR_BADCHANNELKEY] = 2,
    [N.ERR_BADCHANMASK] = 2,
    [N.ERR_NEEDREGGEDNICK] = 2,
    [N.ERR_BANLISTFULL] = 2,        -- <channel> <mode> :reason
    [N.ERR_BADCHANNAME] = 2,
    [N.ERR_THROTTLE] = 2,
    [N.ERR_CHANOPRIVSNEEDED] = 2,
    [N.ERR_VOICENEEDED] = 2,
    [N.ERR_KEYSET] = 2,
    [N.ERR_MLOCKRESTRICTED] = 2,    -- <channel> <mode> <mlock> :reason
}
