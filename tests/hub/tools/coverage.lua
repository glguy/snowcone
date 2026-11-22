-- Line coverage of hub by its tests, with luacov (luarocks install luacov).
-- tests/hub/tools/coverage.sh runs it over every test; by hand:
--
--   snowcone tests/hub/tools/coverage.lua run STATS TEST.lua
--       run one test file, recording which of hub's lines it ran in STATS
--   lua tests/hub/tools/coverage.lua merge OUT STATS...
--       add several of those together; each of hub's files is named by
--       its path from the repository, however a test loaded it
--
-- A test's run ends with its "1..N" line (lib.lua), or "ok" for the
-- plain test scripts, and its stats are saved then: snowcone may still
-- have work pending, and luacov would otherwise save only at exit.

local mode = arg[1]

-- A chunk's name as a path from the repository, when it is one of hub's:
-- tests/hub/../../hub/net/irc.lua and tests/../hub/net/irc.lua are
-- hub/net/irc.lua; tests/hub/lib.lua is none
local function hub_path(name)
    local path, n = name, 1
    while n > 0 do
        path, n = path:gsub('[^/]+/%.%./', '', 1)
    end
    return path:match '^(hub/.*)$'
end

if mode == 'run' then
    local stats, test = arg[2], arg[3]
    assert(stats and test, 'usage: snowcone coverage.lua run STATS TEST.lua')
    local runner = require 'luacov.runner'
    runner.init {
        statsfile = stats,
        include = {'/hub/', '^hub/'},
        exclude = {'^tests/hub/test', '/tests/hub/'},
        -- save once, when the run ends (below)
        savestepsize = math.maxinteger,
    }
    local print_ = print
    local saved = false
    print = function(...) -- luacheck: ignore 121
        print_(...)
        local line = select('#', ...) == 1 and tostring((...)) or ''
        if not saved and (line:match '^1%.%.%d+$' or line == 'ok') then
            saved = true
            runner.shutdown()
        end
    end
    -- the test sees only its own name, as when run directly
    arg = {[0] = test} -- luacheck: ignore 121
    dofile(test)

elseif mode == 'merge' then
    local out = arg[2]
    assert(out and arg[3], 'usage: lua coverage.lua merge OUT STATS...')
    local stats = require 'luacov.stats'
    local merged = {}
    for i = 3, #arg do
        for name, lines in pairs(stats.load(arg[i]) or {}) do
            local path = hub_path(name)
            if path then
                local into = merged[path] or {max = 0, max_hits = 0}
                merged[path] = into
                into.max = math.max(into.max, lines.max)
                for line = 1, lines.max do
                    local hits = lines[line]
                    if hits then
                        into[line] = (into[line] or 0) + hits
                        into.max_hits = math.max(into.max_hits, into[line])
                    end
                end
            end
        end
    end
    stats.save(out, merged)

else
    error('usage: coverage.lua run STATS TEST.lua | merge OUT STATS...', 0)
end
