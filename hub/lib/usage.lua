-- A command's usage, such as 'nick [reason]', as the placeholders the
-- input line shows for arguments not yet typed.
--
-- A usage is words separated by spaces, one placeholder each:
--
-- [word]        optional; brackets around several words make each optional
-- word...       repeats; last only
--
-- An optional word whose label starts with a sign, as [@tags] does, is
-- taken only by an argument starting with that sign; one that doesn't
-- goes to the next word. Such a word may come before required ones. A
-- label of choices (a|b) has a sign only when every choice starts with
-- it, and a bracket is never one.
--
-- Brackets inside a word, as in address[/prefix] or [nick!]user@host, are
-- part of its label: a bracket counts only when it opens a word and its
-- match closes one.
--
-- Each spec item (lib/mkcommand) takes one placeholder in order; a rest
-- of the line takes all those left, the words typed in it filling them in
-- turn and the last taking whatever remains.

local M = {}

---@class hub.Placeholder
---@field label string
---@field optional boolean
---@field repeats boolean
---@field sign string|nil the sign an argument taking an optional one starts with

-- Words for a spec's arguments, for a usage made from a spec
local spec_words <const> = {
    g = 'word', r = 'text', R = '[text]', t = 'text', T = '[text]', i = 'number', f = 'number',
    v = 'name', q = "'text'", p = 'path',
}

--- A usage made from a spec (lib/mkcommand), its arguments by their kind
--- and its literal words as themselves; nil for no arguments.
---@param spec string
---@return string|nil
function M.of_spec(spec)
    if spec == nil or spec == '' then return nil end
    return (spec:gsub('%$(.)', function(c) return spec_words[c] or '...' end))
end

--- The placeholders of a usage, or nil and why it doesn't parse.
---@param usage string|nil
---@return hub.Placeholder[]|nil, string|nil
function M.parse(usage)
    if usage == nil then return {} end

    -- each bracket's match
    local match, open = {}, {}
    for i = 1, #usage do
        local c = usage:sub(i, i)
        if c == '[' then
            table.insert(open, i)
        elseif c == ']' then
            local j = table.remove(open)
            if not j then return nil, 'unmatched ] in ' .. usage end
            match[i], match[j] = j, i
        end
    end
    if open[1] then return nil, 'unmatched [ in ' .. usage end

    -- the brackets that make words optional: an outer one is settled
    -- before those inside it, as it opens first
    local group = {}
    for i = 1, #usage do
        if usage:sub(i, i) == '[' then
            local j = match[i]
            local before, after = usage:sub(i - 1, i - 1), usage:sub(j + 1, j + 1)
            if (i == 1 or before == ' ' or before == '[' and group[i - 1])
                and (after == '' or after == ' ' or after == ']' and group[j + 1]) then
                group[i], group[j] = true, true
            else
                local space = usage:find(' ', i, true)
                if space and space < j then
                    return nil, 'brackets inside a word span a space in ' .. usage
                end
            end
        end
    end

    local placeholders, depth = {}, 0
    local label, optional = {}, false
    local function finish()
        if not label[1] then return end
        local text = table.concat(label)
        local base = text:match '^(.-)%.%.%.$'
        local sign = optional and text:match '^[^%w\'"%[]' or nil
        for choice in text:gmatch '[^|]+' do
            if sign and choice:sub(1, 1) ~= sign then sign = nil end
        end
        table.insert(placeholders, {label = base or text, optional = optional, repeats = base ~= nil, sign = sign})
        label, optional = {}, false
    end
    for i = 1, #usage do
        local c = usage:sub(i, i)
        if c == ' ' then
            finish()
        elseif group[i] then
            depth = depth + (c == '[' and 1 or -1)
            if c == ']' and not label[1] then return nil, 'an empty [] in ' .. usage end
        else
            if not label[1] then optional = depth > 0 end
            table.insert(label, c)
        end
    end
    finish()
    return placeholders
end

--- Each spec item's placeholders, or nil and why they don't line up.
---@param items hub.SpecItem[]
---@param placeholders hub.Placeholder[]
---@return hub.Placeholder[][]|nil, string|nil
function M.align(items, placeholders)
    local slots, n = {}, 1
    for i, item in ipairs(items) do
        if item.rest then
            if not placeholders[n] then return nil, 'nothing for the rest of the line' end
            slots[i] = table.move(placeholders, n, #placeholders, 1, {})
            n = #placeholders + 1
        else
            if not placeholders[n] then return nil, 'fewer words than arguments' end
            slots[i] = {placeholders[n]}
            n = n + 1
        end
    end
    if placeholders[n] then return nil, 'more words than arguments' end
    return slots
end

--- Why a usage doesn't fit its spec, or nil when it does. A command that
--- gives its own placeholders (`dynamic`) may put an optional argument
--- before a required one, which placeholders in order can't follow.
---@param items hub.SpecItem[]
---@param placeholders hub.Placeholder[]
---@param dynamic boolean|nil
---@return string|nil
function M.check(items, placeholders, dynamic)
    local slots, err = M.align(items, placeholders)
    if not slots then return err end
    for i, slot in ipairs(slots) do
        local item = items[i]
        local required
        for _, p in ipairs(slot) do required = required or not p.optional and p end
        if item.optional and not slot[1].optional then
            return 'an argument that may be empty shown as required: ' .. slot[1].label
        elseif not item.optional and not required then
            return 'a required argument shown as optional: ' .. slot[1].label
        elseif item.literal and slot[1].label ~= item.literal then
            return 'the word ' .. item.literal .. ' shown as ' .. slot[1].label
        end
    end
    local seen_optional
    for i, p in ipairs(placeholders) do
        if p.repeats and i < #placeholders then
            return 'a repeating argument before the last: ' .. p.label
        end
        if p.optional then
            if not p.sign then seen_optional = p end
        elseif seen_optional and not dynamic then
            return 'an optional argument before a required one: ' .. seen_optional.label
        end
    end
    return nil
end

--- The placeholders to show after a line's arguments: those of the items
--- not yet typed, and, in a rest of the line, those its words haven't
--- reached. A repeating one stays shown however many have been typed.
---@param slots hub.Placeholder[][] from align
---@param analysis hub.ArgsAnalysis of the arguments
---@param args string the arguments analyzed
---@return hub.Placeholder[]
function M.pending(slots, analysis, args)
    local shown = {}
    local n = #analysis.words
    local last = analysis.words[n]
    if last and analysis.items[n].rest then
        -- each word takes the next placeholder, past optional ones whose
        -- sign it doesn't start with
        local slot, k = slots[n], 1
        for word in args:sub(last.lo, last.hi):gmatch '[^ ]+' do
            while k < #slot and slot[k].sign and word:sub(1, #slot[k].sign) ~= slot[k].sign do
                k = k + 1
            end
            k = k + 1
        end
        for j = k, #slot do table.insert(shown, slot[j]) end
        if not shown[1] and slot[#slot].repeats then table.insert(shown, slot[#slot]) end
    end
    if not analysis.leftover then
        for i = n + 1, #slots do
            table.move(slots[i], 1, #slots[i], #shown + 1, shown)
        end
    end
    return shown
end

return M
