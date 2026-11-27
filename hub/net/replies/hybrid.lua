-- What OFTC hybrid's numeric replies mean, for their summaries in the
-- message detail (ui/details/message.lua). Most have Solanum's arguments
-- (net/replies/solanum.lua, which documents the field kinds); these are
-- where hybrid's numbers or arguments differ.

local NH      <const> = require 'hub.lib.numerics_hybrid'
local read    <const> = require 'hub.net.replies.read'
local solanum <const> = require 'hub.net.replies.solanum'
local tablex  <const> = require 'pl.tablex'

local M = {}

M.line_types = tablex.update(tablex.copy(solanum.line_types), {
    I = 'auth block',
})

--- The flags an auth block's user mask starts with in an I-line
--- (RPL_STATSILINE), by sigil; ^ _ > and < are shown only to opers. The
--- line has no password or redirect: a * stands in the password's place.
M.auth_flags = {
    ['-'] = 'no_tilde',
    ['!'] = 'limit_ip',
    ['+'] = 'need_ident',
    ['&'] = 'no_password',
    ['$'] = 'exempt_resv',
    ['%'] = 'no_match_ip',
    ['='] = 'spoof',
    ['^'] = 'kline_exempt',
    ['_'] = 'gline_exempt',
    ['>'] = 'exceed_limit',
    ['<'] = 'idlelined',
    ['|'] = 'can_flood',
}
M.auth_redirects = false
M.auth_passwords = false

local text <const> = {'text:text'}

M.fields = tablex.copy(solanum.fields)

-- Solanum's numbers that hybrid doesn't send, or sends meaning another
-- reply, without fields below
for _, n in ipairs {8, 43, 270, 310, 325, 330, 335, 360, 378, 415, 416, 417,
    435, 470, 477, 480, 484, 486, 489, 492, 517, 670, 671, 691, 707,
    716, 718, 729, 730, 731, 732, 733, 734, 740, 741, 742, 743, 750, 751,
    900, 901, 902, 903, 904, 905, 906, 907, 908} do
    M.fields[n] = nil
end

tablex.update(M.fields, {
    [NH.RPL_TRACECAPTURED] = {'-', 'class', 'client', 'ip:addr', 'heard:secs', 'idle:secs'},
    [NH.RPL_STATSQLINE] = {'type:line', 'mask', 'reason:text'},
    [NH.RPL_STATSYLINE] = {'-', 'class', 'ping:secs', 'connfreq:secs', 'max', 'sendq', 'users', 'state'},
    [NH.RPL_STATSPLINE] = {'-', 'port', 'name', 'refs', 'flags', 'state:text'},
    [NH.RPL_LOCALUSERS] = text,
    [NH.RPL_GLOBALUSERS] = text,
    [NH.RPL_ADMINME] = text,
    [NH.RPL_WHOISSSL] = {'nick', 'text:text'},
    [NH.RPL_WHOISNICKSERVREG] = {'nick', 'text:text'},
    [NH.RPL_WHOISADMIN] = {'nick', 'text:text'},
    [NH.RPL_WHOISSERVICE] = {'nick', 'text:text'},
    [NH.RPL_WHOISREAL] = {'nick', 'text:text'},
    [NH.RPL_QUIETLIST] = {'channel', 'mask', 'by', 'set:time'},
    [NH.RPL_ENDOFQUIETLIST] = {'channel', 'text:text'},
    [NH.ERR_CANTSENDREGONLY] = {'channel', 'text:text'},
    [NH.ERR_REGONLYCHAN] = {'channel', 'text:text'},
    [NH.ERR_SSLONLYCHAN] = {'channel', 'text:text'},
    [NH.ERR_RESTRICTED] = text,
    [NH.RPL_MODLIST] = {'module', 'address', 'version', 'origin'},
    [NH.RPL_TARGUMODEG] = {'nick', 'text:text'},
    [NH.RPL_UMODEGMSG] = {'nick', 'text:text'},
    [NH.RPL_WHOISACTUALLY] = {'nick', 'address', 'text:text'},
    [NH.RPL_TESTMASK] = {'mask', 'local', 'remote', 'text:text'},
    -- ETRACE without a host, or -full with the host and server the client
    -- gave in its USER
    [NH.RPL_ETRACE] = {'type', 'class', 'nick', 'user', 'ip:addr', 'realname:text'},
    [NH.RPL_ETRACEFULL] = {'type', 'class', 'nick', 'user', 'ip:addr', 'USER host', 'USER server', 'realname:text'},
    [NH.RPL_ISCAPTURED] = {'nick', 'text:text'},
    [NH.RPL_ISUNCAPTURED] = {'nick', 'text:text'},
})

--- Solanum's readers but MODLIST's, whose arguments differ.
M.readers = {
    [NH.RPL_STATSILINE] = read.auth_block,
    [NH.RPL_STATSLINKINFO] = read.link,
}

return M
