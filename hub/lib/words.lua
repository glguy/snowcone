-- The words of a line of chat worth spell checking: words(text).

-- Code points that are part of words: ASCII letters, and other
-- characters but for punctuation, symbols and emoji
local function is_letter(c)
    if c < 0x80 then
        return 0x41 <= c and c <= 0x5a or 0x61 <= c and c <= 0x7a
    end
    if c <= 0xbf or c == 0xd7 or c == 0xf7 then return false end
    if 0x2000 <= c and c <= 0x2bff then return false end -- punctuation, arrows, symbols
    if 0x3000 <= c and c <= 0x303f then return false end -- CJK punctuation
    if 0xfe00 <= c and c <= 0xfe0f then return false end -- variation selectors
    if c == 0xfeff or c == 0xfffd then return false end -- BOM, replacement
    if 0xff00 <= c and c <= 0xff20 then return false end -- fullwidth punctuation
    if c >= 0x1f000 then return false end -- emoji and pictographs
    return true
end

local function is_apostrophe(c)
    return c == 0x27 or c == 0x2019
end

local function is_digit(c)
    return 0x30 <= c and c <= 0x39
end

local function is_hex(c)
    return is_digit(c) or 0x41 <= c and c <= 0x46 or 0x61 <= c and c <= 0x66
end

-- Formatting codes that take no parameters: bold, reset, monospace,
-- reverse, italic, strikethrough, underline
local style_codes <const> = {
    [0x02] = true, [0x0f] = true, [0x11] = true, [0x16] = true,
    [0x1d] = true, [0x1e] = true, [0x1f] = true,
}

-- Up to n code points from i that pass p; the index after them
local function skip(cps, i, n, p)
    local j = i
    while j < i + n and p(cps[j].c) do j = j + 1 end
    return j
end

-- Exactly n code points from i that pass p: the index after them, or i
local function skip_exactly(cps, i, n, p)
    local j = skip(cps, i, n, p)
    return j == i + n and j or i
end

-- The text of a line in tokens, split at spaces and at control
-- characters other than formatting codes. A formatting code and its
-- parameters are left out of the token but don't end it, so a word
-- with a code inside it is still one word. Each code point keeps its
-- first and last bytes, p and e. Color parameters are read as
-- ui/irc_formatting.lua reads them: ^C takes one or two digits, then a
-- comma and one or two more; ^D takes six hex digits, then a comma and
-- six more, or nothing.
local function tokens(text)
    local cps = {}
    for p, c in utf8.codes(text) do
        cps[#cps + 1] = {p = p, c = c}
    end
    cps[#cps + 1] = {p = #text + 1, c = 0x20} -- ends the last token
    for i = 1, #cps - 1 do cps[i].e = cps[i + 1].p - 1 end

    local out, token = {}, {}
    local i = 1
    while i <= #cps do
        local c = cps[i].c
        if c == 0x03 then
            i = i + 1
            local j = skip(cps, i, 2, is_digit)
            if j > i and cps[j].c == 0x2c and is_digit(cps[j + 1].c) then
                j = skip(cps, j + 1, 2, is_digit)
            end
            i = j
        elseif c == 0x04 then
            i = i + 1
            local j = skip_exactly(cps, i, 6, is_hex)
            if j > i and cps[j].c == 0x2c then
                local k = skip_exactly(cps, j + 1, 6, is_hex)
                if k > j + 1 then j = k end
            end
            i = j
        elseif style_codes[c] then
            i = i + 1
        elseif c <= 0x20 or c == 0x7f then
            if token[1] then table.insert(out, token) end
            token = {}
            i = i + 1
        else
            table.insert(token, cps[i])
            i = i + 1
        end
    end
    return out
end

-- The text of code points i to j of a token, without formatting
local function text_of(token, i, j)
    local t = {}
    for k = i, j do t[#t + 1] = utf8.char(token[k].c) end
    return table.concat(t)
end

-- The byte ranges of code points i to j of a token: one for each run
-- between formatting codes
local function ranges_of(token, i, j)
    local ranges = {{lo = token[i].p, hi = token[i].e}}
    for k = i + 1, j do
        local last = ranges[#ranges]
        if token[k].p == last.hi + 1 then
            last.hi = token[k].e
        else
            table.insert(ranges, {lo = token[k].p, hi = token[k].e})
        end
    end
    return ranges
end

-- Tokens that aren't prose: URLs, channels, words with digits, names
-- with dots like example.com
local function prose(text)
    if text:find('://', 1, true) then return false end
    if text:find '^[#&]' then return false end
    if text:find '%d' then return false end
    if text:find '%a%.%a' then return false end
    return true
end

-- Characters of nicks, for the token a word may be part of
local nick_chars <const> = '%w%[%]\\`_%^{|}%-'
local trim_nick <const> = '^[^' .. nick_chars .. ']*(.-)[^' .. nick_chars .. ']*$'

---@class hub.SpellWord
---@field word string the word as checked, without formatting codes
---@field lo integer its first byte in the line
---@field hi integer its last byte
---@field ranges {lo: integer, hi: integer}[] the bytes of its text, split
--- where formatting codes come between
---@field name string the space-separated token holding it, without
--- formatting or the punctuation around it, to compare with nicks

--- The words of a line worth checking, in order. Inner apostrophes are
--- part of a word.
---@param text string valid UTF-8
---@return hub.SpellWord[]
return function(text)
    local out = {}
    if not utf8.len(text) then return out end
    for _, token in ipairs(tokens(text)) do
        local whole = text_of(token, 1, #token)
        if prose(whole) then
            local name = whole:match(trim_nick)
            local i, n = 1, #token
            while i <= n do
                if is_letter(token[i].c) then
                    local j = i
                    while j < n and (is_letter(token[j + 1].c)
                        or is_apostrophe(token[j + 1].c) and j + 1 < n and is_letter(token[j + 2].c)) do
                        j = j + 1
                    end
                    table.insert(out, {
                        word = text_of(token, i, j),
                        lo = token[i].p,
                        hi = token[j].e,
                        ranges = ranges_of(token, i, j),
                        name = name,
                    })
                    i = j + 1
                else
                    i = i + 1
                end
            end
        end
    end
    return out
end
