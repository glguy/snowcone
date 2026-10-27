-- End-to-end checks for snowcone.start_httpd, run as: snowcone FILE
-- Requests are made with curl through snowcone.execute. Any error fails the
-- run; the script ends when the last listener is closed.

local port <const> = arg[1] or '18765'
local spare_port <const> = arg[2] or '18766'

-- Run body as a coroutine so each step can wait on a callback in order
local function sequence(body)
    local co = coroutine.create(body)
    local function step(...)
        local ok, err = coroutine.resume(co, ...)
        if not ok then
            error(debug.traceback(co, err), 0)
        end
    end
    step(step)
end

local resume

local function curl(args, input)
    local argv = {'-s', '-o', '-', '-w', '\n%{http_code}', '--max-time', '10'}
    table.move(args, 1, #args, #argv + 1, argv)
    snowcone.execute('curl', argv, function(...) resume(...) end, {input = input})
    local code, out, err = coroutine.yield()
    assert(code, 'curl did not start: ' .. tostring(out))
    return code, out, err
end

local function expect(label, actual, expected)
    if actual ~= expected then
        error(string.format('%s: expected %q, got %q', label, tostring(expected), tostring(actual)), 2)
    end
    print('ok  ' .. label)
end

-- Responses are "body\nstatus"; with several URLs, one line pair per URL
local function responses(out)
    local result = {}
    for body, status in out:gmatch('([^\n]*)\n(%d%d%d)') do
        result[#result + 1] = status .. ' ' .. body
    end
    return table.concat(result, ', ')
end

local errors = {}

local function server(tag)
    return function(method, target, body, headers)
        if method == nil then
            errors[#errors + 1] = tag .. ' ' .. target .. ': ' .. body
            return
        end
        if target == '/length' then
            return 200, tostring(#body)
        elseif target == '/header' then
            return 200, tostring(headers['x-mixed-case'])
        elseif target == '/nothing' then
            return
        elseif target == '/raise' then
            error('handler failure', 0)
        elseif target == '/raise-table' then
            error({})
        elseif target:match '^/status/' then
            return tonumber(target:match '^/status/(.*)'), 'status'
        elseif target == '/bad-header' then
            return 200, 'x', {['X-Bad'] = 'a\r\nInjected: 1'}
        elseif target == '/reload-soon' then
            -- Reload after this response is sent, while the client still
            -- holds the keep-alive connection
            RELOAD_TIMER = snowcone.newtimer()
            RELOAD_TIMER:start(100, function()
                SERVER:close()
                SERVER = snowcone.start_httpd('127.0.0.1', port, server('gen2'))
            end)
        end
        return 200, tag, {['Content-Type'] = 'text/plain'}
    end
end

local function url(path, p)
    return 'http://127.0.0.1:' .. (p or port) .. path
end

local function take_errors()
    local result = table.concat(errors, '; ')
    errors = {}
    return result
end

sequence(function(step)
    resume = step

    -- Closing during the resolve means the closed listener never binds
    local early = snowcone.start_httpd('127.0.0.1', port, server('closed-early'))
    early:close()
    SERVER = snowcone.start_httpd('127.0.0.1', port, server('gen1'))

    -- A listener nothing refers to is closed when collected
    snowcone.start_httpd('127.0.0.1', spare_port, server('garbage'))
    collectgarbage()
    collectgarbage()

    -- Give the resolves time to finish
    local wait = snowcone.newtimer()
    wait:start(200, function() step() end)
    coroutine.yield()

    local _, out = curl {url '/'}
    expect('restart after close during resolve', responses(out), '200 gen1')

    local code = curl {url('/', spare_port)}
    expect('collected listener refuses connections (curl exit 7)', code, 7)

    -- Handler contract
    _, out = curl {url '/nothing'}
    expect('handler returning nothing', responses(out):match('^%d+'), '500')
    _, out = curl {url '/raise'}
    expect('handler raising an error', responses(out):match('^%d+'), '500')
    local reported = take_errors()
    expect('handler error reported', reported:match '^[^\n]*', 'gen1 handler: handler failure')
    expect('handler error has a traceback', reported:find('stack traceback:', 1, true) ~= nil, true)
    _, out = curl {url '/raise-table'}
    expect('handler raising a table', responses(out):match('^%d+'), '500')
    expect('table error reported', take_errors():match '^gen1 handler: table: ' ~= nil, true)

    -- Header names reach the handler in lower case
    _, out = curl {'-H', 'X-Mixed-CASE: yes', url '/header'}
    expect('header names in lower case', responses(out), '200 yes')

    -- Status codes: any integer from 100 to 999, reported otherwise
    _, out = curl {url '/status/299'}
    expect('unregistered status passes through', responses(out), '299 status')
    for _, bad in ipairs {'99', '1000', '-1', '200.5', '4294967496'} do
        out = select(2, curl {url('/status/' .. bad)})
        expect('status ' .. bad .. ' refused', responses(out):match('^%d+'), '500')
        expect('status ' .. bad .. ' reported', take_errors(),
            'gen1 handler: status must be an integer from 100 to 999')
    end
    _, out = curl {url '/bad-header'}
    expect('header with CR LF refused', responses(out):match('^%d+'), '500')
    expect('bad header reported', take_errors(),
        'gen1 handler: header names and values must be strings without CR, LF or NUL')

    -- Request limits
    _, out = curl({'--data-binary', '@-', url '/length'}, string.rep('x', 25 * 1024 * 1024))
    expect('25 MiB body accepted', responses(out), '200 ' .. 25 * 1024 * 1024)
    _, out = curl({'--data-binary', '@-', url '/length'}, string.rep('x', 30 * 1024 * 1024))
    expect('30 MiB body refused', responses(out), '413 Payload Too Large')
    expect('body limit reported', take_errors(), 'gen1 read: body limit exceeded')
    _, out = curl {'-H', 'X-Big: ' .. string.rep('y', 9000), url '/'}
    expect('oversized header refused', responses(out), '431 Request Header Fields Too Large')
    expect('header limit reported', take_errors(), 'gen1 read: header limit exceeded')

    -- Websocket upgrades are ordinary requests
    _, out = curl {
        '-H', 'Connection: Upgrade', '-H', 'Upgrade: websocket',
        '-H', 'Sec-WebSocket-Version: 13', '-H', 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
        url '/'
    }
    expect('upgrade request handled as plain HTTP', responses(out), '200 gen1')

    -- Reload while curl holds a keep-alive connection: the second request
    -- must reach the new handler, not the old one
    _, out = curl {'--rate', '2/s', url '/reload-soon', url '/'}
    expect('keep-alive request after reload', responses(out), '200 gen1, 200 gen2')

    expect('no unexpected httpd errors', take_errors(), '')

    SERVER:close()
end)
