-- Structural rules of hub's source: layering, the tiers within ui,
-- which features may use each other, who reads which part of HUB,
-- which layer may use which native API, and the event catalog.
--
-- Run with:  snowcone tests/hub/test-structure.lua

local dir  = require 'pl.dir'
local file = require 'pl.file'
local path = require 'pl.path'

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local root = path.normpath(path.abspath(T.root))

local layer_rank = {lib = 1, runtime = 2, net = 3, features = 4, commands = 5, ui = 6, app = 7}

-- Tiers within ui, lowest first; a ui module requires only its own tier
-- or lower. Modules not named are in tier 3 (views, details and the like).
local ui_tier = {
    ['ui/draw.lua'] = 1, ['ui/pads.lua'] = 1, ['ui/clicks.lua'] = 1,
    ['ui/colors.lua'] = 1, ['ui/fields.lua'] = 1, ['ui/irc_formatting.lua'] = 1,
    ['ui/editor.lua'] = 1,
    ['ui/control.lua'] = 2,
    ['ui/keymap.lua'] = 4,
    ['ui/init.lua'] = 5,
}
local function tier_of(rel)
    return ui_tier[rel] or 3
end

-- A feature may require another feature's modules only when it needs that
-- feature (config_schema.feature_requires), or as listed here
local feature_uses <const> = {
    -- notify follows chat's buffers; it isn't a per-network feature
    notify = {chat = true},
}

-- Parts of HUB that only one layer reads or writes
local hub_owner <const> = {
    ['HUB%.state%.ui'] = 'ui',
}

-- Layer of a path relative to the hub root, like 'ui/views/status.lua'
local function layer_of_path(rel)
    local top = rel:match '^([^/]+)/'
    if top == nil then
        return 'app' -- init.lua, app.lua
    end
    return top
end

-- Layer of a module name, like 'hub.ui.views.status'
local function layer_of_module(name)
    local top = name:match '^hub%.([^.]+)'
    if top == 'app' then return 'app' end
    return top
end

-- Native functions and the only layer allowed to call them
local native_owner = {
    ['snowcone.connect'] = 'net',
    ['snowcone.newtimer'] = 'runtime',
    ['snowcone.dnslookup'] = 'runtime',
    ['snowcone.execute'] = 'runtime',
    ['snowcone.setmodule'] = 'runtime',
    ['snowcone.stop_input'] = 'runtime',
    ['snowcone.start_input'] = 'runtime',
    ['snowcone.catch_signals'] = 'runtime',
}

local function strip_comments(src)
    -- block comments, then line comments; good enough for our own sources
    src = src:gsub('%-%-%[(=*)%[.-%]%1%]', '')
    src = src:gsub('%-%-[^\n]*', '')
    return src
end

local function sources()
    local list = {}
    for _, filename in ipairs(dir.getallfiles(root, '*.lua')) do
        local rel = path.relpath(filename, root)
        -- type declarations for the language server, never loaded
        if rel ~= 'types.lua' then
            table.insert(list, {rel = rel, src = strip_comments(assert(file.read(filename)))})
        end
    end
    table.sort(list, function(a, b) return a.rel < b.rel end)
    return list
end

local function module_exists(name)
    local rel = name:gsub('^hub%.', ''):gsub('%.', '/')
    return path.isfile(path.join(root, rel .. '.lua'))
        or path.isfile(path.join(root, rel, 'init.lua'))
end

T.case('modules only require their own layer or below', function()
    local problems = {}
    for _, f in ipairs(sources()) do
        local mine = layer_of_path(f.rel)
        T.ok(layer_rank[mine], 'known layer for ' .. f.rel)
        for name in f.src:gmatch 'require%s*%(?%s*[\'"](hub%.[%w_.]+)[\'"]' do
            local theirs = layer_of_module(name)
            if not layer_rank[theirs] then
                table.insert(problems, f.rel .. ': unknown layer in ' .. name)
            elseif layer_rank[theirs] > layer_rank[mine] then
                table.insert(problems, string.format('%s (%s) requires %s (%s)', f.rel, mine, name, theirs))
            elseif mine == 'lib' and theirs ~= 'lib' then
                table.insert(problems, f.rel .. ': lib requires ' .. name)
            end
            if not module_exists(name) then
                table.insert(problems, f.rel .. ': no such module ' .. name)
            end
        end
    end
    T.eq(problems, {}, 'layering problems')
end)

-- The path of a module inside hub, like 'ui/views/status.lua'
local function module_path(name)
    local rel = name:gsub('^hub%.', ''):gsub('%.', '/')
    if path.isfile(path.join(root, rel .. '.lua')) then
        return rel .. '.lua'
    end
    return rel .. '/init.lua'
end

T.case('ui modules only require their own tier or below', function()
    local problems = {}
    for _, f in ipairs(sources()) do
        if layer_of_path(f.rel) == 'ui' then
            for name in f.src:gmatch 'require%s*%(?%s*[\'"](hub%.ui[%w_.]*)[\'"]' do
                local theirs = module_path(name)
                if tier_of(theirs) > tier_of(f.rel) then
                    table.insert(problems, string.format('%s (tier %d) requires %s (tier %d)',
                        f.rel, tier_of(f.rel), name, tier_of(theirs)))
                end
            end
        end
    end
    T.eq(problems, {}, 'ui tier problems')
end)

T.case('features use each other only as they require', function()
    local requires = dofile(path.join(root, 'runtime/config_schema.lua')).feature_requires
    local function allowed(mine, theirs)
        if feature_uses[mine] and feature_uses[mine][theirs] then return true end
        for _, needed in ipairs(requires[mine] or {}) do
            if needed == theirs then return true end
        end
        return false
    end

    local problems = {}
    for _, f in ipairs(sources()) do
        -- a feature's own directory, or nil for a shared helper (features/*.lua)
        local mine = f.rel:match '^features/([^/]+)/'
        if layer_of_path(f.rel) == 'features' then
            for name in f.src:gmatch 'require%s*%(?%s*[\'"]hub%.features%.([%w_.]+)[\'"]' do
                local theirs = name:match '^[^.]+'
                -- a shared helper is anyone's; a feature's directory is its own
                if path.isdir(path.join(root, 'features', theirs)) and theirs ~= mine then
                    if mine == nil then
                        table.insert(problems, f.rel .. ': a shared helper requires feature ' .. theirs)
                    elseif not allowed(mine, theirs) then
                        table.insert(problems, string.format('%s: %s uses %s, which it does not require',
                            f.rel, mine, theirs))
                    end
                end
            end
        end
    end
    T.eq(problems, {}, 'feature dependency problems')
end)

T.case('each part of HUB is used only by its layer', function()
    local problems = {}
    for _, f in ipairs(sources()) do
        local mine = layer_of_path(f.rel)
        if mine == 'lib' and f.src:find 'HUB[^%w_]' then
            table.insert(problems, f.rel .. ': lib uses HUB')
        end
        for pattern, owner in pairs(hub_owner) do
            if mine ~= owner and f.src:find(pattern .. '[^%w_]') then
                table.insert(problems, string.format('%s: uses %s outside %s',
                    f.rel, pattern:gsub('%%', ''), owner))
            end
        end
    end
    table.sort(problems)
    T.eq(problems, {}, 'HUB ownership problems')
end)

T.case('native APIs are used only from their layer', function()
    local problems = {}
    for _, f in ipairs(sources()) do
        local mine = layer_of_path(f.rel)
        if mine ~= 'ui' and f.src:find 'ncurses%.' then
            table.insert(problems, f.rel .. ': uses ncurses outside ui')
        end
        for name, owner in pairs(native_owner) do
            local pattern = name:gsub('%.', '%%.') .. '[^%w_]'
            if mine ~= owner and f.src:find(pattern) then
                table.insert(problems, string.format('%s: calls %s outside %s', f.rel, name, owner))
            end
        end
    end
    table.sort(problems)
    T.eq(problems, {}, 'native API problems')
end)

T.case('every emitted topic is listed in EVENTS.md', function()
    local listed = {}
    for topic in assert(file.read(path.join(root, 'EVENTS.md'))):gmatch '\n| `([^`]+)` |' do
        listed[topic] = true
    end
    T.ok(listed['log'], 'EVENTS.md parsed')

    local missing = {}
    for _, f in ipairs(sources()) do
        -- whole literals only: 'snote.' .. name is a family of topics
        for _, pattern in ipairs {'bus%.emit%(%s*[\'"]([^\'"]+)[\'"]%s*,', ':emit%(%s*[\'"]([^\'"]+)[\'"]%s*,'} do
            for topic in f.src:gmatch(pattern) do
                if not listed[topic] then
                    table.insert(missing, f.rel .. ': ' .. topic)
                end
            end
        end
    end
    T.eq(missing, {}, 'topics missing from EVENTS.md')
end)

T.run()
