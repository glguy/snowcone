-- /list's filters, as the network's ISUPPORT ELIST offers them, made
-- into LIST's argument:
--
--   #mask *mask* ?mask   the channels matching a mask (M); a channel name
--                        alone needs no ELIST
--   !mask                leaving out those matching it (N)
--   >n <n                more, or fewer, than n users (U)
--   C<n C>n              created within the last n minutes, or longer
--                        ago (C)
--   T<n T>n              the topic set within the last n minutes, or
--                        longer ago (T); a channel without one is left out
--
-- A filter is a word; LIST gets them joined by commas. Each kind goes
-- once, as Solanum keeps only the last of a kind, and a mask starts with a
-- channel type, * or ?, which Solanum needs and OFTC hybrid takes. The
-- exclusion never goes first: Solanum reads a ! there, from an oper with
-- operspy, as LIST !<filters>, operspy over the rest. Solanum reads seven
-- filters at most.
--
-- ELIST's draft leaves C and T's direction open; OFTC hybrid reads C the
-- other way about from Solanum (its modules/m_list.c: C<n created more
-- than n minutes ago), so a C filter goes to it turned around. The
-- listing shows the filters as typed.
--
-- Without filters a server may leave out its smallest channels (Solanum's
-- displayed_usercount); any filter, such as >0, lists them.

local ircd <const> = require 'hub.net.ircd'

local M = {}

-- What each ELIST letter filters by, as an error names it
local offers <const> = {
    U = 'user count', C = 'creation time', T = 'topic time', M = 'mask', N = 'mask to leave out',
}

-- The order the filters go in: the masks last, the exclusion after the mask
local order <const> = {'>', '<', 'C>', 'C<', 'T>', 'T<', 'M', 'N'}

-- Each kind as an error names it
local kind_names <const> = {
    ['>'] = '>n', ['<'] = '<n', ['C>'] = 'C>n', ['C<'] = 'C<n', ['T>'] = 'T>n', ['T<'] = 'T<n',
    M = 'mask', N = '!mask',
}

-- Solanum multiplies minutes by 60 in an int, which overflows past
-- 35791394; users and minutes stay well below
local max_number <const> = 9999999

local max_filters <const> = 7

local function number(word, text, least)
    local n = text:match '^%d+$' and math.tointeger(tonumber(text))
    if not n then error('not a number: ' .. word, 0) end
    if n > max_number then error('too large: ' .. word, 0) end
    if n < least then error(word .. ' lists nothing', 0) end
    return n
end

-- A mask starts with a channel type, * or ?
local function check_mask(irc, word, mask)
    local first = mask:sub(1, 1)
    if mask == '' or not (first == '*' or first == '?' or irc.chantypes:find(first, 1, true)) then
        error('a mask starts with a channel type (' .. irc.chantypes .. '), * or ?: ' .. word, 0)
    end
end

--- A filter word: its kind (an entry of order) and value, and the ELIST
--- letter it needs.
---@return string kind
---@return string|integer value
---@return string letter
local function read_filter(irc, word)
    local op, n = word:match '^([<>])(.*)$'
    if op then
        -- fewer than 0 lists nothing; OFTC hybrid refuses <0
        return op, number(word, n, op == '<' and 1 or 0), 'U'
    end
    local letter, cmp, minutes = word:match '^([CcTt])([<>])(.*)$'
    if letter then
        letter = letter:upper()
        return letter .. cmp, number(word, minutes, 0), letter
    end
    local excluded = word:match '^!(.*)$'
    if excluded then
        check_mask(irc, word, excluded)
        return 'N', excluded, 'N'
    end
    check_mask(irc, word, word)
    return 'M', word, 'M'
end

--- LIST's argument for filter words, on a network.
---@class hub.ListFilter
---@field arg string|nil as sent; nil for every channel
---@field shown string the command as typed, the filters in our order
---@field channel string|nil the one channel named, for no such channel

---@param net string
---@param irc table the network's model
---@param words string[]
---@return hub.ListFilter
function M.parse(net, irc, words)
    local by_kind = {}
    for _, word in ipairs(words) do
        local kind, value, letter = read_filter(irc, word)
        if by_kind[kind] then error('one ' .. kind_names[kind] .. ' filter: ' .. word, 0) end
        by_kind[kind] = {value = value, letter = letter}
    end
    if #words > max_filters then error('at most ' .. max_filters .. ' filters', 0) end

    -- a channel named alone is plain LIST, which needs no ELIST
    local mask = by_kind.M
    local alone = #words == 1 and mask and not mask.value:find '[*?]'
    if not alone and #words > 0 then
        local elist = irc.isupport.ELIST
        local letters = type(elist) == 'string' and elist:upper() or ''
        for _, f in pairs(by_kind) do
            if not letters:find(f.letter, 1, true) then
                error(string.format('%s has no LIST by %s (ELIST=%s)', net, offers[f.letter],
                    letters ~= '' and letters or 'none'), 0)
            end
        end
    end

    local hybrid = ircd.hybrid(net)
    local sent, shown = {}, {}
    for _, kind in ipairs(order) do
        local f = by_kind[kind]
        if f then
            local function token(k)
                if k == 'M' then return f.value end
                if k == 'N' then return '!' .. f.value end
                return k .. f.value
            end
            table.insert(shown, token(kind))
            local as_sent = kind
            if hybrid and kind:sub(1, 1) == 'C' then as_sent = kind == 'C<' and 'C>' or 'C<' end
            if kind == 'N' and not sent[1] then table.insert(sent, '*') end
            table.insert(sent, token(as_sent))
        end
    end

    return {
        arg = sent[1] and table.concat(sent, ',') or nil,
        shown = shown[1] and 'LIST ' .. table.concat(shown, ',') or 'LIST',
        channel = alone and mask.value or nil,
    }
end

return M
