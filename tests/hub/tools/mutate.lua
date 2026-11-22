-- Mutation testing of hub: comment out one line at a time and see whether
-- any test notices.
--
--   lua tests/hub/tools/mutate.lua [-j JOBS] [-t TEST,...] FILE...
--
-- FILE is a hub module, such as hub/net/handlers.lua. Each line luac
-- counts as code, unless it is a lone keyword, is commented out in a
-- scratch copy of the tree; if the copy still parses, the tests run,
-- stopping at the first that fails. A mutant no test fails is listed:
-- either nothing checks what that line does, or the line changes nothing
-- anyone can observe (a log line, a redraw, a default set again later).
--
--   -j JOBS   copies of the tree to test in at once (default 8)
--   -t TESTS  test files to run, by name, comma-separated
--             (default: every tests/hub/test-*.lua)
--
-- The copies are git worktrees with the working tree's hub/ and tests/
-- copied in, so uncommitted changes count; they are removed at the end
-- (after an interruption, `git worktree prune` once they are deleted).
-- SNOWCONE names the client (default: snowcone on the PATH). A test run
-- is cut off after 60 s, so a mutant that loops forever counts as caught.

local function q(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function capture(cmd)
    local p = assert(io.popen(cmd))
    local out = p:read 'a'
    p:close()
    return out
end

local function read(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read 'a'
    f:close()
    return s
end

local function write(path, s)
    local f = assert(io.open(path, 'wb'))
    f:write(s)
    f:close()
end

local function lines_of(s)
    local lines = {}
    for line in (s .. '\n'):gmatch '([^\n]*)\n' do table.insert(lines, line) end
    lines[#lines] = nil -- the empty piece after the last newline
    return lines
end

-- Lines that only close or continue a construct: commenting them out
-- can't parse, so they aren't worth a luac run
local structural <const> = {
    [''] = true, ['end'] = true, ['else'] = true, ['end)'] = true, ['end,'] = true,
    ['}'] = true, ['})'] = true, ['},'] = true, ['end))'] = true, ['do'] = true,
}

-- A worker tests every jobs-th mutant from its own, in its copy of the tree
local function worker(base, index, jobs)
    local cfg = dofile(base .. '/config.lua')
    local wt = base .. '/wt' .. index
    local out = assert(io.open(base .. '/result' .. index, 'w'))
    for k, job in ipairs(cfg.mutants) do
        if (k - 1) % jobs == index - 1 then
            local original = read(cfg.root .. '/' .. job.file)
            local lines = lines_of(original)
            lines[job.line] = '-- MUTANT ' .. lines[job.line]
            local target = wt .. '/' .. job.file
            write(target, table.concat(lines, '\n') .. '\n')
            local status, by = 'invalid', ''
            if os.execute('luac -p ' .. q(target) .. ' 2>/dev/null') then
                status = 'survived'
                for _, test in ipairs(cfg.tests) do
                    local ok, _, code = os.execute(string.format(
                        "cd %s && perl -e 'alarm shift; exec @ARGV' 60 %s %s >/dev/null 2>&1",
                        q(wt), q(cfg.snowcone), q(test)))
                    if not ok and code ~= 77 then
                        status, by = 'killed', test
                        break
                    end
                end
            end
            write(target, original)
            out:write(job.file, '\t', job.line, '\t', status, '\t', by, '\n')
            out:flush()
        end
    end
    out:close()
end

local function main(args)
    local jobs, tests, files = 8, nil, {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == '-j' then
            jobs = assert(math.tointeger(tonumber(args[i + 1])), '-j needs a number')
            i = i + 1
        elseif a == '-t' then
            tests = {}
            for name in args[i + 1]:gmatch '[^,]+' do
                table.insert(tests, 'tests/hub/' .. name:gsub('%.lua$', '') .. '.lua')
            end
            i = i + 1
        else
            table.insert(files, a)
        end
        i = i + 1
    end
    assert(#files > 0, 'usage: lua mutate.lua [-j JOBS] [-t TEST,...] FILE...')

    local here = arg[0]:match '^(.*)/[^/]*$' or '.'
    local root = capture('cd ' .. q(here .. '/../../..') .. ' && pwd'):gsub('\n$', '')
    if not tests then
        tests = {}
        for name in capture('cd ' .. q(root) .. ' && ls tests/hub/test-*.lua'):gmatch '[^\n]+' do
            table.insert(tests, name)
        end
    end

    local mutants = {}
    for _, file in ipairs(files) do
        local listing = capture('luac -p -l ' .. q(root .. '/' .. file))
        local code = {}
        for n in listing:gmatch '\n%s+%d+%s+%[(%d+)%]' do code[tonumber(n)] = true end
        local lines = lines_of(read(root .. '/' .. file))
        for n = 1, #lines do
            local text = lines[n]:match '^%s*(.-)%s*$'
            if code[n] and not structural[text] and not text:find '^%-%-' then
                table.insert(mutants, {file = file, line = n, text = text})
            end
        end
    end

    local base = os.tmpname()
    os.remove(base)
    assert(os.execute('mkdir -p ' .. q(base)))
    io.stderr:write(string.format('%d mutants, %d tests, %d at once, in %s\n', #mutants, #tests, jobs, base))
    local cfg = {root = root, tests = tests, snowcone = os.getenv 'SNOWCONE' or 'snowcone', mutants = {}}
    for k, m in ipairs(mutants) do cfg.mutants[k] = {file = m.file, line = m.line} end
    write(base .. '/config.lua', 'return ' .. require 'pl.pretty'.write(cfg))

    local spawn = {}
    for w = 1, jobs do
        local wt = base .. '/wt' .. w
        assert(os.execute(string.format(
            'git -C %s worktree add -q --detach %s HEAD && rm -rf %s/hub %s/tests && cp -R %s/hub %s/tests %s/',
            q(root), q(wt), q(wt), q(wt), q(root), q(root), q(wt))))
        table.insert(spawn, string.format('lua %s --worker %s %d %d', q(arg[0]), q(base), w, jobs))
    end
    os.execute(table.concat(spawn, ' & ') .. ' & wait')

    local results = {}
    for w = 1, jobs do
        for line in io.lines(base .. '/result' .. w) do
            local file, n, status = line:match '^([^\t]*)\t(%d+)\t([^\t]*)\t'
            results[file .. ':' .. n] = status
        end
        os.execute(string.format('git -C %s worktree remove --force %s', q(root), q(base .. '/wt' .. w)))
    end
    os.execute('rm -rf ' .. q(base))

    local counts = {}
    print 'Not caught by any test:'
    for _, m in ipairs(mutants) do
        local status = results[m.file .. ':' .. m.line] or 'missing'
        local c = counts[m.file] or {killed = 0, survived = 0, invalid = 0, missing = 0}
        counts[m.file] = c
        c[status] = c[status] + 1
        if status == 'survived' then
            print(string.format('  %s:%d: %s', m.file, m.line, m.text))
        end
    end
    print ''
    for _, file in ipairs(files) do
        local c = counts[file] or {killed = 0, survived = 0, invalid = 0, missing = 0}
        local tried = c.killed + c.survived
        print(string.format('%-32s caught %4d, not caught %4d, score %3.0f%%%s', file, c.killed, c.survived,
            tried > 0 and 100 * c.killed / tried or 0, c.missing > 0 and (', ' .. c.missing .. ' not run') or ''))
    end
end

if arg[1] == '--worker' then
    worker(arg[2], tonumber(arg[3]), tonumber(arg[4]))
else
    main(arg)
end
