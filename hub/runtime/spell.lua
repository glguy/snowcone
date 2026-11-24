-- Spell checking with hunspell ([spell]): the words of a line worth
-- checking (lib/words.lua), which of them are misspelled, suggestions,
-- and a personal word list that /spell_add appends to.
--
-- Each generation opens the dictionary as it activates, closing the one
-- before, so /reload re-reads the dictionary and the personal list and
-- repeats an error opening them. The handle is native, so it is held in
-- runtime/resources; HUB.state.spell keeps its id.

local words     <const> = require 'hub.lib.words'
local config    <const> = require 'hub.runtime.config'
local log       <const> = require 'hub.runtime.log'
local resources <const> = require 'hub.runtime.resources'
local path      <const> = require 'pl.path'
local dir       <const> = require 'pl.dir'

local M = {}

--- The open dictionary, if any (HUB.state.spell).
---@class hub.SpellState
---@field id integer|nil the hunspell handle in runtime/resources
---@field utf8 boolean|nil the dictionary is UTF-8; otherwise only ASCII words are checked
---@field personal string|nil the personal word list's path

function M.init_state(S)
    S.spell = S.spell or {}
end

-- Verdicts by word for this generation's dictionary, remembered up to a
-- limit and then started over: typing checks the whole line on every key
local verdict_limit <const> = 5000
local verdicts, n_verdicts = {}, 0

local function personal_path(cfg)
    if cfg.personal then
        return config.resolve_path(path.expanduser(cfg.personal))
    end
    return path.join(config.config_dir(), 'words')
end

-- The words of the personal list, one per line
local function read_personal(file)
    local f, err, code = io.open(file, 'r')
    if not f then
        if code == 2 then return {} end -- ENOENT: not written yet
        error(err, 0)
    end
    local ok, text = pcall(f.read, f, 'a')
    f:close()
    if not ok or text == nil then
        error(string.format('%s: %s', file, ok and 'unreadable' or text), 0)
    end
    text = text:gsub('^\xef\xbb\xbf', '') -- a UTF-8 byte order mark
    local list = {}
    for line in text:gmatch '[^\n]+' do
        local word = line:match '^%s*(.-)%s*$'
        if word ~= '' then table.insert(list, word) end
    end
    return list
end

-- Open the dictionary and add the personal words; raises with a message
local function open(base, personal)
    local h = myhunspell.open(base .. '.aff', base .. '.dic')
    local ok, err = pcall(function()
        local encoding = h:encoding()
        for _, word in ipairs(read_personal(personal)) do h:add(word) end
        return encoding
    end)
    if not ok then
        h:close()
        error(err, 0)
    end
    return h, (err:upper():gsub('[^%w]', '')) == 'UTF8'
end

--- Open the configured dictionary, closing the one before.
function M.activate()
    local S = HUB.state.spell
    if S.id then resources.close(S.id) end
    HUB.state.spell = {}
    verdicts, n_verdicts = {}, 0

    local cfg = HUB.state.config and HUB.state.config.spell
    if not cfg then return end
    if not myhunspell then
        log.add('error', 'spell: snowcone was built without hunspell')
        return
    end
    local ok, h, info = pcall(function()
        local base = config.resolve_path(path.expanduser(cfg.dictionary))
        ---@cast base string
        -- the files' shared name, should one of them be named
        base = base:gsub('%.dic$', ''):gsub('%.aff$', '')
        local personal = personal_path(cfg)
        local handle, is_utf8 = open(base, personal)
        return handle, {utf8 = is_utf8, personal = personal}
    end)
    if not ok then
        log.add('error', 'spell: %s', h)
        return
    end
    HUB.state.spell = {
        id = resources.add('spell', 'spell', h, 'close'),
        utf8 = info.utf8,
        personal = info.personal,
    }
end

-- The open dictionary's handle, and whether it is UTF-8
---@return myhunspell.Handle|nil
---@return boolean|nil
local function handle()
    local S = HUB.state.spell
    local h = S and S.id and resources.get(S.id)
    if h then return h, S.utf8 end
end

--- Spell checking is configured and its dictionary opened.
function M.available()
    return handle() ~= nil
end

--- Why spell checking isn't available.
---@return string
function M.unavailable_reason()
    if not (HUB.state.config and HUB.state.config.spell) then
        return 'spell checking is not configured ([spell])'
    elseif not myhunspell then
        return 'snowcone was built without hunspell'
    end
    return 'the dictionary could not be opened; /reload tries again'
end

--- Whether the open dictionary can judge a word: one that isn't UTF-8
--- judges only ASCII words.
---@param word string
---@return boolean
function M.checkable(word)
    local h, utf8 = handle()
    return h ~= nil and (utf8 or not word:find '[\x80-\xff]')
end

local function correct(h, word)
    local v = verdicts[word]
    if v == nil then
        v = not M.checkable(word) or h:spell(word)
        if n_verdicts >= verdict_limit then
            verdicts, n_verdicts = {}, 0
        end
        verdicts[word] = v
        n_verdicts = n_verdicts + 1
    end
    return v
end

--- Whether a word is spelled correctly, or can't be judged; nil
--- without a dictionary.
---@param word string
---@return boolean|nil
function M.check(word)
    local h = handle()
    if h then return correct(h, word) end
end

-- A word is a name: a nick, a nick's possessive, or part of a nick
local function named(w, is_nick)
    if not is_nick then return false end
    local stem = w.word:match "^(.-)'s$" or w.word:match '^(.-)\u{2019}s$'
    return is_nick(w.word) or is_nick(w.name) or stem ~= nil and is_nick(stem)
end

-- The cursor at byte `at` is in w (at its first byte too, unless after
-- only), just after it, or just after an apostrophe that ends it
local function touches(text, w, at, after_only)
    if (after_only and w.lo < at or not after_only and w.lo <= at) and at <= w.hi + 1 then
        return true
    end
    local rest = text:sub(w.hi + 1, at - 1)
    return rest == "'" or rest == '\u{2019}'
end

--- The misspelled words of a line. A word for which is_nick is true is
--- a name, never misspelled, as is a word whose token is a nick
--- (foo_bar) or that is a nick's possessive. The word the cursor at
--- byte `typing` is in or just after is still being typed, and isn't
--- judged yet; one just after the cursor is.
---@param text string
---@param is_nick (fun(word: string): boolean)|nil
---@param typing integer|nil
---@return hub.SpellWord[]
function M.misspelled(text, is_nick, typing)
    local h = handle()
    local out = {}
    if not h then return out end
    for _, w in ipairs(words(text)) do
        if not (typing and touches(text, w, typing, true))
        and not named(w, is_nick)
        and not correct(h, w.word) then
            table.insert(out, w)
        end
    end
    return out
end

--- The byte ranges of a line's misspelled words, for drawing.
---@param text string
---@param is_nick (fun(word: string): boolean)|nil
---@param typing integer|nil
---@return {lo: integer, hi: integer}[]
function M.misspelled_ranges(text, is_nick, typing)
    local out = {}
    for _, w in ipairs(M.misspelled(text, is_nick, typing)) do
        table.move(w.ranges, 1, #w.ranges, #out + 1, out)
    end
    return out
end

--- The misspelled word to correct with the cursor at byte `at`: the one
--- it touches, or else the last before it.
---@param text string
---@param at integer
---@param is_nick (fun(word: string): boolean)|nil
---@return hub.SpellWord|nil
function M.pick(text, at, is_nick)
    local before
    for _, w in ipairs(M.misspelled(text, is_nick)) do
        if touches(text, w, at) then return w end
        if w.hi < at then before = w end
    end
    return before
end

--- Suggested spellings of a word, best first; empty without a dictionary.
---@param word string
---@return string[]
function M.suggest(word)
    local h, utf8 = handle()
    if not h then return {} end
    local t = h:suggest(word)
    if not utf8 then
        local ascii = {}
        for _, w in ipairs(t) do
            if not w:find '[\x80-\xff]' then table.insert(ascii, w) end
        end
        t = ascii
    end
    return t
end

-- Append a line to a file, after a line break if its last line has none
local function append_line(file, line)
    local f, err = io.open(file, 'a+')
    if not f then return nil, err end
    local size = f:seek 'end'
    local sep = ''
    if size and size > 0 then
        f:seek('set', size - 1)
        if f:read(1) ~= '\n' then sep = '\n' end
        f:seek 'end' -- stdio needs a seek between reading and writing
    end
    local ok, werr = f:write(sep, line, '\n')
    f:close()
    if not ok then return nil, werr end
    return true
end

--- Accept a word from now on, and in later sessions through the
--- personal word list. The word must be one the checker sees whole.
---@param word string
---@return true|nil
---@return string|nil error
function M.add(word)
    local h = handle()
    if not h then return nil, M.unavailable_reason() end
    local ws = utf8.len(word) and words(word) or {}
    if not (#ws == 1 and ws[1].word == word) then
        return nil, word .. ' is not a word the spell checker sees whole'
    end
    if not M.checkable(word) then
        return nil, word .. " can't be checked with this dictionary"
    end
    local personal = HUB.state.spell.personal
    ---@cast personal -nil set with the handle
    local ok, listed = pcall(read_personal, personal)
    local known = false
    for _, w in ipairs(ok and listed or {}) do
        if w == word then known = true end
    end
    if not known then
        local parent = path.dirname(personal)
        if parent ~= '' and not path.isdir(parent) then
            local made, err = dir.makepath(parent)
            if not made then return nil, err end
        end
        local written, err = append_line(personal, word)
        if not written then return nil, err end
    end
    h:add(word)
    -- other forms of the word (its capitalized form) may be correct now
    verdicts, n_verdicts = {}, 0
    return true
end

--- The personal word list's path; nil without spell checking.
---@return string|nil
function M.personal_path()
    return handle() and HUB.state.spell.personal
end

return M
