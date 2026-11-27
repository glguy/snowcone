-- Replies whose arguments take reading beyond their fields: each reader
-- makes a reply into a record of what it says, for the message detail
-- (ui/details/message.lua) and the listings' tables
-- (ui/details/listing.lua) to show as each does. A network's replies
-- (net/replies/solanum.lua, hybrid.lua) name the readers of its numerics
-- in `readers`; `meant` is that table.

local M = {}

--- An auth block (STATS I, or TESTLINE matching no ban).
---@class hub.AuthBlock
---@field user string
---@field host string|nil nil when the mask has none
---@field hidden boolean the server won't say the host
---@field flags {[1]: string, [2]: string}[] each sigil and its name
---@field class string|nil
---@field spoof string|nil the name a spoofed block gives its users
---@field redirect string|nil the server a block sends its users to
---@field redirect_port string|nil the port, unless the default
---@field password string|nil '(hidden)' when the server hides it
---@field description string|nil

--- I <name> <password> <sigils><user>@<host> <port> <class>
--- :<description>: the flags are the sigils before the user, which the
--- network's auth_flags name.
---@param meant table
---@param msg hub.Message
---@return hub.AuthBlock
function M.auth_block(meant, msg)
    local name, password, mask, port, class = msg[3], msg[4], msg[5] or '', msg[6], msg[7]
    local sigils = {}
    for sigil in pairs(meant.auth_flags) do table.insert(sigils, '%' .. sigil) end
    local prefix, user, host = mask:match('^([' .. table.concat(sigils) .. ']*)([^@]*)@(.*)$')
    if not prefix then prefix, user, host = '', mask, nil end
    local block = {user = user, host = host, hidden = host == '255.255.255.255', flags = {}, class = class}
    local spoofed = false
    for sigil in prefix:gmatch '.' do
        table.insert(block.flags, {sigil, meant.auth_flags[sigil]})
        if sigil == '=' then spoofed = true end
    end
    if spoofed then
        -- hybrid gives * for a block without a spoof name
        if name and name ~= '*' then block.spoof = name end
    elseif meant.auth_redirects and name and name ~= 'NOMATCH' and name ~= '<NULL>' then
        block.redirect = name
        if port and port ~= '0' and port ~= '' then block.redirect_port = port end
    end
    if meant.auth_passwords and password and password ~= '<NULL>' then
        block.password = password == '*' and '(hidden)' or password
    end
    if #msg > 7 then block.description = msg[#msg] end
    return block
end

--- A server link (STATS L).
---@class hub.Link
---@field name string|nil
---@field sendq string|nil
---@field sent_msgs string|nil
---@field sent_kib string|nil
---@field recv_msgs string|nil
---@field recv_kib string|nil
---@field open integer|nil seconds
---@field idle integer|nil seconds
---@field times string|nil the last argument, when it isn't the times
---@field caps string|nil

--- <name> <sendq> <sent messages> <sent KiB> <received messages>
--- <received KiB> :<seconds open> <seconds idle> <capabilities>, the
--- capabilities - for none.
---@param msg hub.Message
---@return hub.Link
function M.link(_, msg)
    local open, idle, caps = (msg[8] or ''):match '^(%d+) (%d+) ?(.*)$'
    return {
        name = msg[2], sendq = msg[3], sent_msgs = msg[4], sent_kib = msg[5], recv_msgs = msg[6], recv_kib = msg[7],
        open = math.tointeger(tonumber(open)), idle = math.tointeger(tonumber(idle)),
        times = not open and msg[8] or nil,
        caps = caps ~= '-' and caps ~= '' and caps or nil,
    }
end

--- A module loaded (Solanum's MODLIST).
---@class hub.Module
---@field name string|nil
---@field address string|nil 0x and hex digits
---@field origin string|nil builtin or extension
---@field core boolean
---@field version string|nil
---@field description string|nil

--- <name> 0x<address> <origin>[ (core)] :[Version <version>]
--- [Description: <description>] (modules/core/m_modules.c).
---@param msg hub.Message
---@return hub.Module
function M.module(_, msg)
    local last = #msg > 4 and msg[#msg] or ''
    local version, description = last:match '^%[Version (.-)%] %[Description: (.*)%]$'
    return {
        name = msg[2], address = msg[3], origin = msg[4], core = #msg > 5 and msg[5] == '(core)',
        version = version, description = version and description or (last ~= '' and last or nil),
    }
end

return M
