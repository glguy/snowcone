-- Becoming an operator: oper.automatic (net/oper.lua) and CHALLENGE
-- (net/challenge.lua), on Solanum and OFTC hybrid.
--
-- Run with:  snowcone tests/hub/test-oper-login.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local N = dofile(here .. '/netlib.lua')(T)
local network, boot, record, register, register_labeled = N.network, N.boot, N.record, N.register, N.register_labeled

T.case('oper.automatic tries its credentials in order until one works', function()
    local fake = boot {network('test', {oper = {automatic = {'first', 'second'}, credentials = {
        {name = 'first', mechanism = 'password', username = 'one', password = 'p1'},
        {name = 'second', mechanism = 'password', username = 'two', password = 'p2'},
        {name = 'unused', mechanism = 'password', username = 'three', password = 'p3'},
    }}})}
    local c = fake.last()
    register(c)
    local sent = c:take()
    T.eq(sent[#sent], 'OPER one p1', 'the first credential')
    c:recv ':srv 464 me :Password incorrect'
    T.eq(c:take(), {'OPER two p2'}, 'then the next')
    c:recv ':srv 381 me :You are now an IRC operator'
    T.eq(c:take(), {}, 'nothing after success')
    T.eq(T.log_lines 'oper', {'password mismatch', 'oper up'}, 'each outcome logged')
end)

-- Answer a CHALLENGE as the server would, with or without labels
local function challenge_exchange(labeled)
    local fake = boot {network('test')}
    local c = fake.last()
    if labeled then register_labeled(c) else register(c) c:take() end

    local pem = assert(io.open(here .. '/../../myopenssl/test/rsa.pem')):read 'a'
    local task = T.require 'hub.runtime.task'
    local challenge = T.require 'hub.net.challenge'
    task.spawn('challenge', {net = 'test'}, challenge, {username = 'oper', key = pem})

    local secret = 'the challenge secret'
    local key = myopenssl.read_pem(pem, true)
    local encoded = mybase64.to_base64(key:encrypt(secret, 'oaep'))
    local half = #encoded // 2
    local sent = record 'irc.sent'
    local lines = {
        ':srv 740 me :' .. encoded:sub(1, half),
        ':srv 740 me :' .. encoded:sub(half + 1),
        ':srv 741 me :End of CHALLENGE',
    }
    if labeled then
        T.eq(c:take(), {'@label=sc1 CHALLENGE oper'}, 'labeled')
        c:recv '@label=sc1 :srv BATCH +c labeled-response'
        for _, line in ipairs(lines) do c:recv('@batch=c ' .. line) end
        c:recv ':srv BATCH -c'
    else
        T.eq(c:take(), {'CHALLENGE oper'}, 'unlabeled')
        for _, line in ipairs(lines) do c:recv(line) end
    end

    local response = mybase64.to_base64(myopenssl.get_digest('sha1'):digest(secret))
    if labeled then
        T.eq(c:take(), {'@label=sc2 CHALLENGE +' .. response}, 'labeled response')
        c:recv '@label=sc2 :srv 381 me :You are now an IRC operator'
    else
        T.eq(c:take(), {'CHALLENGE +' .. response}, 'response')
        c:recv ':srv 381 me :You are now an IRC operator'
    end
    T.eq(T.log_lines 'challenge', {'oper up'}, 'opered')
    T.eq(sent[1].msg[1], '\x0304*', 'the response is kept out of the logs')
    T.eq(next(HUB.tasks), nil, 'finished')
end

T.case('CHALLENGE with labeled-response', function() challenge_exchange(true) end)

T.case('CHALLENGE without labeled-response', function() challenge_exchange(false) end)

-- Start CHALLENGE on a registered network; returns the connection,
-- its first CHALLENGE line taken
local function challenge_started(labeled)
    local fake = boot {network('test')}
    local c = fake.last()
    if labeled then register_labeled(c) else register(c) c:take() end
    local pem = assert(io.open(here .. '/../../myopenssl/test/rsa.pem')):read 'a'
    T.require 'hub.runtime.task'.spawn('challenge', {net = 'test'}, T.require 'hub.net.challenge',
        {username = 'oper', key = pem})
    c:take()
    return c, myopenssl.read_pem(pem, true)
end

T.case('CHALLENGE stops at what the server says instead of a challenge', function()
    local c = challenge_started(false)
    c:recv ':srv 381 me :You are now an IRC operator'
    T.eq(T.log_lines 'challenge', {'already oper'}, 'already oper')
    T.eq(c:take(), {}, 'no response')

    c = challenge_started(false)
    c:recv ':srv 491 me :No O-lines for your host'
    T.eq(T.log_lines 'challenge', {'host mismatch'}, 'host mismatch')
    T.eq(c:take(), {}, 'no response')

    c = challenge_started(true)
    c:recv '@label=sc1 :srv ACK'
    T.eq(T.log_lines 'challenge', {'no challenge from the server'}, 'a reply without a challenge')
    T.eq(c:take(), {}, 'no response')
end)

T.case('CHALLENGE reports a response the server refuses', function()
    local c, key = challenge_started(false)
    local encoded = mybase64.to_base64(key:encrypt('secret', 'oaep'))
    c:recv(':srv 740 me :' .. encoded)
    c:recv ':srv 741 me :End of CHALLENGE'
    T.ok(c:take()[1]:find '^CHALLENGE %+', 'responded')
    c:recv ':srv 464 me :Password Incorrect'
    T.eq(T.log_lines 'challenge', {'key mismatch'}, 'key mismatch')
    T.eq(next(HUB.tasks), nil, 'finished')
end)

T.case('CHALLENGE on OFTC hybrid', function()
    local fake = boot {network('test', {ircd = 'oftc-hybrid'})}
    local c = fake.last()
    register(c)
    c:take()

    local pem = assert(io.open(here .. '/../../myopenssl/test/rsa.pem')):read 'a'
    local task = T.require 'hub.runtime.task'
    local challenge = T.require 'hub.net.challenge'
    task.spawn('challenge', {net = 'test'}, challenge, {username = 'oper', key = pem})
    T.eq(c:take(), {'CHALLENGE oper'}, 'asked')

    local secret = string.rep('\x01\xfe', 16)
    local key = myopenssl.read_pem(pem, true)
    local hex = key:encrypt(secret):gsub('.', function(ch) return string.format('%02x', string.byte(ch)) end)
    c:recv(':srv 386 me :' .. hex)
    T.eq(c:take(), {'CHALLENGE +' .. string.rep('01FE', 16)}, 'the secret in hex')
    c:recv ':srv 381 me :You have entered... the Twilight Zone!'
    T.eq(T.log_lines 'challenge', {'oper up'}, 'opered')
    T.eq(next(HUB.tasks), nil, 'finished')
end)

T.case('CHALLENGE on OFTC hybrid stops at a failure notice', function()
    local fake = boot {network('test', {ircd = 'oftc-hybrid'})}
    local c = fake.last()
    register(c)
    c:take()
    local pem = assert(io.open(here .. '/../../myopenssl/test/rsa.pem')):read 'a'
    local task = T.require 'hub.runtime.task'
    task.spawn('challenge', {net = 'test'}, T.require 'hub.net.challenge', {username = 'oper', key = pem})
    c:take()
    c:recv ':bob!b@h NOTICE me :hello'
    T.ok(next(HUB.tasks), 'a user notice is not an answer')
    c:recv ":srv NOTICE me :I'm sorry, PK authentication is not enabled for your oper{} block."
    T.eq(T.log_lines 'challenge', {'no key in the oper block'}, 'said why')
    T.eq(next(HUB.tasks), nil, 'finished at once')
end)

T.run()
