-- Command argument specs.
--
-- A spec is words separated by spaces; each is a literal word the
-- arguments must repeat, or one of:
--
-- $g        a word: anything up to a space
-- $a        a word sent before a line's last IRC parameter, so not
--           starting with : (lib/irc_param)
-- $p        a path name, as a word
-- $v        an identifier (ASCII letters, digits and _, not starting with a digit)
-- $i        an integer that fits one, optionally signed
-- $f        a decimal number
-- $q        a string in ' or " quotes, without them
-- $r        the rest of the line, not empty; last only
-- $R        the rest of the line, possibly empty; last only
-- $t        message text: the rest of the line, not empty; last only
-- $T        message text, possibly empty; last only
--
-- Arguments are separated by one or more spaces; spaces after the last
-- are ignored. A word is a run of bytes other than space, whatever the
-- locale, so UTF-8 names come through whole. The arguments must fit the
-- spec entirely: a word left over is an error, not dropped.
--
-- Message text is matched as the rest of the line is; the input line
-- shows it as it will be seen, formatting and all, and checks its
-- spelling.
--
-- A compiled spec has two sides that walk the arguments the same way:
-- the matcher, for running a command, and the analyzer, for showing a
-- line while it is typed, which goes on past a word that doesn't fit.

local irc_param <const> = require 'hub.lib.irc_param'

-- Check and convert one word for a kind; nil when it doesn't fit
local word_kinds <const> = {
    g = function(w) return w end,
    a = function(w) return irc_param.middle(w) and w or nil end,
    p = function(w) return w end,
    v = function(w) return w:match '^[A-Za-z_][A-Za-z0-9_]*$' end,
    i = function(w)
        return w:match '^[+-]?%d+$' and math.tointeger(tonumber(w)) or nil
    end,
    f = function(w)
        if w:match '^[+-]?%d*%.?%d+$' or w:match '^[+-]?%d*%.?%d+[eE][+-]?%d+$' then
            return tonumber(w)
        end
    end,
}

--- One item of a spec: a literal word, or a kind of argument.
---@class hub.SpecItem
---@field literal string|nil the word the arguments must repeat
---@field kind string|nil the letter after $
---@field rest boolean|nil the rest of the line ($r, $R, $t or $T)
---@field optional boolean|nil a rest of the line that may be empty ($R or $T)
---@field text boolean|nil message text ($t or $T)

--- An argument as typed, for the spec item at the same index.
---@class hub.ArgWord
---@field lo integer first byte, in the arguments
---@field hi integer last byte
---@field ok boolean it fits its item

--- What the arguments of a line make of a spec. words[i] is the word for
--- items[i]; the items after the last word are missing (a rest of the
--- line typed empty has no word). Past the last item, leftover covers the
--- text that fits none, from its first word to its last.
---@class hub.ArgsAnalysis
---@field items hub.SpecItem[] the spec's items, shared: not to be changed
---@field words hub.ArgWord[]
---@field leftover {lo: integer, hi: integer}|nil
---@field ok boolean the arguments fit the spec entirely
---@field params any[] the values, when ok

--- The end of a word that starts at pos: the closing quote of a $q string
--- and whether it closes one, or the byte before the next space. A $q
--- string never closed runs to the end, as one still being typed.
---@return integer hi, boolean closed
local function word_end(args, pos, item)
    if item.kind == 'q' then
        local quote = args:sub(pos, pos)
        if quote == '"' or quote == "'" then
            local close = args:find(quote, pos + 1, true)
            if not close then return #args, false end
            local next_char = args:sub(close + 1, close + 1)
            if next_char == '' or next_char == ' ' then return close, true end
        end
    end
    return (args:find(' ', pos, true) or #args + 1) - 1, item.kind ~= 'q'
end

---@param items hub.SpecItem[]
---@param args string
---@return hub.ArgsAnalysis
local function analyze(items, args)
    local a = {items = items, words = {}, ok = true, params = {}}
    local pos = args:match '^ *()'
    for _, item in ipairs(items) do
        if item.rest then
            local value = args:sub(pos)
            if value ~= '' then
                table.insert(a.words, {lo = pos, hi = #args, ok = true})
            elseif not item.optional then
                a.ok = false
            end
            table.insert(a.params, value)
            pos = #args + 1
        elseif pos > #args then
            a.ok = false
            break
        else
            local hi, closed = word_end(args, pos, item)
            local value
            if not closed then
                value = nil
            elseif item.literal then
                if args:sub(pos, hi) == item.literal then value = true end
            elseif item.kind == 'q' then
                value = args:sub(pos + 1, hi - 1)
            else
                value = word_kinds[item.kind](args:sub(pos, hi))
            end
            table.insert(a.words, {lo = pos, hi = hi, ok = value ~= nil})
            if value == nil then
                a.ok = false
            elseif not item.literal then
                table.insert(a.params, value)
            end
            pos = args:match('^ *()', hi + 1)
        end
    end
    if pos <= #args then
        a.leftover = {lo = pos, hi = args:match('^.*[^ ]()', pos) - 1}
        a.ok = false
    end
    return a
end

--- Compile a spec into a matcher and an analyzer: matcher(args, params)
--- fills params and returns true when args fit the spec; analyzer(args)
--- tells what each part of args is.
---@param spec string
---@return fun(args: string, params: table): boolean matcher
---@return fun(args: string): hub.ArgsAnalysis analyzer
return function(spec)
    local items = {}
    for token in spec:gmatch '[^ ]+' do
        local kind = token:match '^%$(.)$'
        if kind == nil then
            table.insert(items, {literal = token})
        elseif word_kinds[kind] or kind == 'q' then
            table.insert(items, {kind = kind})
        elseif kind == 'r' or kind == 'R' or kind == 't' or kind == 'T' then
            local optional = kind == 'R' or kind == 'T' or nil
            local text = kind == 't' or kind == 'T' or nil
            table.insert(items, {kind = kind, rest = true, optional = optional, text = text})
        else
            error('unknown spec type in ' .. spec .. ': ' .. token, 2)
        end
    end
    for i, item in ipairs(items) do
        if item.rest and i < #items then
            error('rest of line before the end of ' .. spec, 2)
        end
    end

    local function analyzer(args)
        return analyze(items, args)
    end

    local function matcher(args, params)
        local a = analyze(items, args)
        if not a.ok then return false end
        table.move(a.params, 1, #a.params, #params + 1, params)
        return true
    end

    return matcher, analyzer
end
