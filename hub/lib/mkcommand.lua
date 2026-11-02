-- Command argument specs.
--
-- A spec is words separated by spaces; each is a literal word the
-- arguments must repeat, or one of:
--
-- $g        a word: anything up to a space
-- $p        a path name, as a word
-- $v        an identifier (ASCII letters, digits and _, not starting with a digit)
-- $i        an integer that fits one, optionally signed
-- $f        a decimal number
-- $q        a string in ' or " quotes, without them
-- $r        the rest of the line, not empty; last only
-- $R        the rest of the line, possibly empty; last only
--
-- Arguments are separated by one or more spaces; spaces after the last
-- are ignored. A word is a run of bytes other than space, whatever the
-- locale, so UTF-8 names come through whole. The arguments must fit the
-- spec entirely: a word left over is an error, not dropped.

-- Check and convert one word for a kind; nil when it doesn't fit
local word_kinds <const> = {
    g = function(w) return w end,
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

--- Compile a spec into a matcher: matcher(args, params) fills params and
--- returns true when args fit the spec.
---@param spec string
---@return fun(args: string, params: table): boolean
return function(spec)
    local items = {}
    for token in spec:gmatch '[^ ]+' do
        local kind = token:match '^%$(.)$'
        if kind == nil then
            table.insert(items, {literal = token})
        elseif word_kinds[kind] or kind == 'q' or kind == 'r' or kind == 'R' then
            table.insert(items, {kind = kind})
        else
            error('unknown spec type in ' .. spec .. ': ' .. token, 2)
        end
    end
    for i, item in ipairs(items) do
        if (item.kind == 'r' or item.kind == 'R') and i < #items then
            error('rest of line before the end of ' .. spec, 2)
        end
    end

    return function(args, params)
        local pos = args:match '^ *()'
        for _, item in ipairs(items) do
            local value
            if item.kind == 'r' or item.kind == 'R' then
                value = args:sub(pos)
                if item.kind == 'r' and value == '' then return false end
                pos = #args + 1
            else
                local word, after
                if item.kind == 'q' then
                    local quote = args:sub(pos, pos)
                    local close = (quote == '"' or quote == "'") and args:find(quote, pos + 1, true)
                    if close then
                        word, after = args:sub(pos + 1, close - 1), close + 1
                    end
                else
                    word, after = args:match('^([^ ]+)()', pos)
                end
                if word == nil then return false end
                -- a word ends at a space or the end
                local next_char = args:sub(after, after)
                if next_char ~= '' and next_char ~= ' ' then return false end

                if item.literal then
                    if word ~= item.literal then return false end
                elseif item.kind == 'q' then
                    value = word
                else
                    value = word_kinds[item.kind](word)
                    if value == nil then return false end
                end
                pos = args:match('^ *()', after)
            end
            if value ~= nil then table.insert(params, value) end
        end
        return pos > #args
    end
end
