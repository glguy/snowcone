-- Structural rules of hub's source (design sections 3 and 9.3): layering,
-- which layer may use which native API, and the event catalogue.
--
-- Run with:  snowcone script tests/hub/test-structure.lua

local dir  = require 'pl.dir'
local file = require 'pl.file'
local path = require 'pl.path'

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local root = path.normpath(path.abspath(T.root))

local layer_rank = {lib = 1, runtime = 2, net = 3, features = 4, ui = 5, commands = 5, app = 6}

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
        table.insert(list, {rel = rel, src = strip_comments(assert(file.read(filename)))})
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
        for _, pattern in ipairs {'bus%.emit%(%s*[\'"]([^\'"]+)[\'"]', ':emit%(%s*[\'"]([^\'"]+)[\'"]'} do
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
