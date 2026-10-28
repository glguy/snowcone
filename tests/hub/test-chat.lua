-- Chat buffers, routing, history, CTCP, notifications and the crypto
-- commands.
--
-- Run with:  snowcone tests/hub/test-chat.lua

local here = (arg and arg[0] or ''):match '^(.*)/[^/]*$' or '.'
local T = dofile(here .. '/lib.lua')
local FakeTransport = dofile(here .. '/fake_transport.lua')

local function boot(extra, global)
    local fake = FakeTransport.new()
    local net = {id = 'test', server = {host = 'test.example', port = 6667}, identity = {nick = 'me'}}
    for k, v in pairs(extra or {}) do net[k] = v end
    local config = {networks = {net}}
    for k, v in pairs(global or {}) do config[k] = v end
    T.boot {transport = fake, config = config}
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :draft/chathistory'
    c:recv ':srv CAP me ACK :draft/chathistory'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 005 me CHANTYPES=# MONITOR=100 CHATHISTORY=50 STATUSMSG=@+ :are supported'
    c:recv ':srv 376 me :End of MOTD'
    c:take()
    return c, T.require 'hub.features.chat'
end

local function texts(buffer)
    local list = {}
    for msg in T.require 'hub.lib.OrderedMap'.reveach(buffer.messages) do
        table.insert(list, tostring(msg.command) .. ' ' .. table.concat(msg, ' '))
    end
    return list
end

T.case('channel and private messages go to buffers', function()
    local c, chat = boot({mention = {patterns = {'%f[%w]me%f[^%w]'}}})
    c:recv ':me!u@h JOIN #chan'
    T.eq(c:take(), {'CHATHISTORY LATEST #chan * 50'}, 'history for a new buffer')
    c:recv ':alice!a@h PRIVMSG #chan :hello all'
    c:recv ':alice!a@h PRIVMSG #chan :hello me'
    c:recv ':bob!b@h PRIVMSG me :psst'
    c:recv ':srv NOTICE * :*** Notice -- not chat'

    local chan = chat.buffer('test', '#CHAN')
    T.eq(texts(chan), {'JOIN #chan', 'PRIVMSG #chan hello all', 'PRIVMSG #chan hello me'}, 'channel')
    T.eq({chan.activity, chan.mention}, {2, true}, 'activity and mention')
    local query = chat.buffer('test', 'Bob')
    T.eq(texts(query), {'PRIVMSG me psst'}, 'private message in a buffer named for the sender')
    T.eq(query.mention, true, 'private messages mention')
    T.eq(chat.buffer('test', '*'), nil, 'server notices are not chat')

    chat.look(chan)
    T.eq({chan.activity, chan.mention}, {0, false}, 'seen')
end)

T.case('global mention patterns apply without network ones', function()
    local c, chat = boot(nil, {mention = {patterns = {'snowcone'}}})
    c:recv ':alice!a@h PRIVMSG #c :I like snowcone'
    T.eq(chat.buffer('test', '#c').mention, true, 'global pattern')
end)

T.case('statusmsg, echo and membership changes', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #c'
    c:recv ':alice!a@h JOIN #c'
    c:recv ':alice!a@h PRIVMSG @#c :ops only'
    local msg = T.require 'hub.lib.OrderedMap'.lookup(chat.buffer('test', '#c').messages, true)
    T.eq(msg.statusmsg, '@', 'statusmsg prefix')

    chat.say('test', '#c', 'from me')
    T.eq(texts(chat.buffer('test', '#c'))[4], 'PRIVMSG #c from me', 'echoed')
    T.eq(chat.buffer('test', '#c').activity, 1, 'our own messages are not activity')

    c:recv ':alice!a@h PRIVMSG me :hi'
    c:recv ':alice!a@h NICK alicia'
    T.eq(chat.buffer('test', 'alice'), nil, 'renamed buffer gone from the old name')
    local renamed = chat.buffer('test', 'alicia')
    T.eq(renamed.name, 'alicia', 'buffer follows the nick')
    T.eq(texts(chat.buffer('test', '#c'))[5], 'NICK alicia', 'nick change in the channel')

    c:recv ':alicia!a@h QUIT :bye'
    T.eq(texts(chat.buffer('test', '#c'))[6], 'QUIT bye', 'quit in the channel the user was in')
    T.eq(texts(renamed)[3], 'QUIT bye', 'and in the private buffer')
end)

T.case('history goes before the message that opened the buffer', function()
    local c, chat = boot()
    c:recv '@time=2026-01-01T00:00:10.000Z :bob!b@h PRIVMSG me :newest'
    c:recv ':srv BATCH +h1 chathistory bob'
    c:recv '@batch=h1;time=2026-01-01T00:00:01.000Z :bob!b@h PRIVMSG me :older'
    c:recv '@batch=h1;time=2026-01-01T00:00:05.000Z :me!u@h PRIVMSG bob :reply'
    c:recv ':srv BATCH -h1'
    T.eq(texts(chat.buffer('test', 'bob')), {'PRIVMSG me older', 'PRIVMSG bob reply', 'PRIVMSG me newest'}, 'in order')

    -- overlapping history (after a reconnect) adds nothing twice
    c:recv ':srv BATCH +h2 chathistory bob'
    c:recv '@batch=h2;time=2026-01-01T00:00:05.000Z :me!u@h PRIVMSG bob :reply'
    c:recv '@batch=h2;time=2026-01-01T00:00:10.000Z :bob!b@h PRIVMSG me :newest'
    c:recv ':srv BATCH -h2'
    T.eq(#texts(chat.buffer('test', 'bob')), 3, 'no duplicates')
end)

T.case('a nick change onto an existing buffer renames nothing', function()
    local c, chat = boot()
    c:recv ':alice!a@h PRIVMSG me :from alice'
    c:recv ':alice_!a@h PRIVMSG me :from alice_'
    c:recv ':alice_!a@h NICK alice'
    T.eq(texts(chat.buffer('test', 'alice')), {'PRIVMSG me from alice'}, 'alice kept')
    T.eq(texts(chat.buffer('test', 'alice_')), {'PRIVMSG me from alice_', 'NICK alice'}, 'alice_ kept, with the change')
end)

T.case('wallops collect in one buffer', function()
    local c, chat = boot()
    c:recv ':oper!o@h WALLOPS :maintenance soon'
    c:recv ':oper!o@h OPERWALL :opers only'
    T.eq(#texts(chat.buffer('test', chat.wallops)), 2, 'both')
end)

T.case('chat history fills its buffer', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #c'
    c:take()
    c:recv ':srv BATCH +h1 chathistory #c'
    c:recv '@batch=h1;time=2026-01-01T00:00:00.000Z :alice!a@h PRIVMSG #c :old one'
    c:recv '@batch=h1;time=2026-01-01T00:00:01.000Z :alice!a@h PRIVMSG +#c :old two'
    c:recv ':srv BATCH -h1'
    local list = texts(chat.buffer('test', '#c'))
    T.eq({list[1], list[3]}, {'PRIVMSG #c old one', 'JOIN #c'}, 'history before the newer JOIN')
    T.eq(chat.buffer('test', '#c').activity, 0, 'history is not activity')
end)

T.case('history after a reconnect goes between old and new messages', function()
    local c, chat = boot()
    c:recv ':me!u@h JOIN #c'
    c:recv '@time=2026-01-01T00:00:09.000Z :alice!a@h PRIVMSG #c :before'
    -- as if registered again: what arrives from now on is the new connection
    HUB.state.nets.test.registered_at = T.require 'hub.runtime.clock'.now()
    c:recv ':alice!a@h PRIVMSG #c :after'
    -- server times that would sort first are not compared
    c:recv ':srv BATCH +h1 chathistory #c'
    c:recv '@batch=h1;time=2000-01-01T00:00:00.000Z :alice!a@h PRIVMSG #c :missed'
    c:recv '@batch=h1;time=2026-01-01T00:00:09.000Z :alice!a@h PRIVMSG #c :before'
    c:recv ':srv BATCH -h1'
    T.eq(texts(chat.buffer('test', '#c')),
        {'JOIN #c', 'PRIVMSG #c before', 'PRIVMSG #c missed', 'PRIVMSG #c after'}, 'in place')
    for msg in T.require 'hub.lib.OrderedMap'.reveach(chat.buffer('test', '#c').messages) do
        T.eq(msg.timestamp == nil, msg[2] == 'missed', 'only history is drawn as old: ' .. tostring(msg[2]))
    end
end)

T.case('history and MONITOR after registration', function()
    local fake = FakeTransport.new()
    T.boot {transport = fake, config = {networks = {
        {id = 'test', server = {host = 'h', port = 1}, identity = {nick = 'me'}}}}}
    local chat = T.require 'hub.features.chat'
    chat.open('test', '#c')
    chat.open('test', 'Bob')
    local c = fake.last()
    c:con()
    c:recv ':srv CAP * LS :draft/chathistory'
    c:recv ':srv CAP me ACK :draft/chathistory'
    c:recv ':srv 001 me :Welcome'
    c:recv ':srv 005 me MONITOR=100 :are supported'
    c:recv ':srv 376 me :End of MOTD'
    local sent = c:take()
    local tablex = T.require 'pl.tablex'
    T.ok(tablex.find(sent, 'CHATHISTORY LATEST #c * 1000'), 'channel history')
    T.ok(tablex.find(sent, 'CHATHISTORY LATEST Bob * 1000'), 'private history')
    T.ok(tablex.find(sent, 'MONITOR + Bob'), 'monitor')
end)

T.case('CTCP replies only to staff', function()
    local c = boot()
    local function notices()
        local list = {}
        for _, line in ipairs(c:take()) do
            if line:match '^NOTICE' then table.insert(list, line) end
        end
        return list
    end
    c:recv ':nobody!n@h PRIVMSG me :\x01VERSION\x01'
    T.eq(notices(), {}, 'ignored')
    c:recv '@solanum.chat/oper :staff!s@h PRIVMSG me :\x01PING 123\x01'
    T.eq(notices(), {'NOTICE staff :\x01PING 123\x01'}, 'answered')
end)

T.case('talk, close and list', function()
    local c, chat = boot()
    T.require 'hub.ui.control'.init_state(HUB.state)
    local cmdline = T.require 'hub.ui.cmdline'
    cmdline.execute 'talk #new'
    local sent = c:take()
    T.eq(sent, {'CHATHISTORY LATEST #new * 50', 'JOIN #new'}, 'history before join')
    cmdline.execute 'talk Carol'
    T.eq(c:take(), {'CHATHISTORY LATEST Carol * 50', 'MONITOR + Carol'}, 'monitor a nick')

    c:recv ':srv 730 me :Carol!c@h'
    chat.close('test', 'carol')
    T.eq(c:take(), {'MONITOR - carol'}, 'unmonitored')
    T.eq(chat.buffer('test', 'Carol'), nil, 'closed')

    cmdline.execute 'list'
    T.eq(c:take(), {'LIST'}, 'LIST')
    c:recv ':srv 321 me Channel :Users  Name'
    c:recv ':srv 322 me #a 12 :topic a'
    c:recv ':srv 322 me #b 3 :topic b'
    c:recv ':srv 323 me :End of /LIST'
    c:recv ':srv 322 me #late 1 :not listed'
    T.eq(chat.get('test').list.n, 2, 'two channels, nothing after the end')
end)

T.case('mentions notify once until seen, and dismiss', function()
    local c, chat = boot(nil, {notifications = {module = 'test'}})
    -- a backend that records what it was asked
    local calls = {}
    HUB.current.gen.loaded['hub.features.notify.test'] = {
        notify = function(previous, target, nick, text)
            table.insert(calls, {'notify', previous or false, target, nick, text})
            return previous or 'handle'
        end,
        dismiss = function(handle) table.insert(calls, {'dismiss', handle}) end,
    }
    local notify = T.require 'hub.features.notify'
    notify.register_backend('test', 'hub.features.notify.test')
    HUB.state.ui = {focus = false}

    c:recv ':bob!b@h PRIVMSG me :one'
    c:recv ':bob!b@h PRIVMSG me :two'
    T.eq(calls, {
        {'notify', false, 'bob', 'bob', 'one'},
        {'notify', 'handle', 'bob', 'bob', 'two'},
    }, 'second notification knows the first')

    HUB.state.ui.focus = true
    c:recv ':bob!b@h PRIVMSG me :three'
    T.eq(#calls, 2, 'no notifications while focused')

    notify.dismiss('test', 'BOB')
    T.eq(calls[3], {'dismiss', 'handle'}, 'dismissed by folded name')
    notify.dismiss('test', 'bob')
    T.eq(#calls, 3, 'only once')
    T.eq(chat.buffer('test', 'bob').mention, true, 'the buffer still shows the mention')
end)

T.case('crypto commands write keys and print the services commands', function()
    boot()
    local dir = os.tmpname()
    os.remove(dir)
    local path = require 'pl.path'
    path.mkdir(dir)
    T.require 'hub.ui.control'.init_state(HUB.state)
    local cmdline = T.require 'hub.ui.cmdline'

    cmdline.execute 'x25519_new'
    local lines = T.log_lines 'crypto'
    T.eq(T.log_lines 'error', {}, 'no errors')
    T.ok(lines[#lines]:match '^/msg NickServ SET X25519%-PUBKEY %S+$', lines[#lines])

    local prompts = {}
    T.require 'hub.runtime.bus'.on(HUB.current.bus, 'task.prompt', 'test', function(ev)
        table.insert(prompts, ev)
    end)
    cmdline.execute('cert_new ' .. dir .. '/cert.pem')
    T.eq(#prompts, 1, 'asked for a password')
    T.require 'hub.runtime.task'.answer(prompts[1].task, '')
    lines = T.log_lines 'crypto'
    local added = lines[#lines]
    T.ok(added:match '^/msg NickServ CERT ADD %x+$', added)

    cmdline.execute('cert_fp ' .. dir .. '/cert.pem')
    lines = T.log_lines 'crypto'
    T.eq(lines[#lines], added, 'same fingerprint from the file')

    os.remove(dir .. '/cert.pem')
    path.rmdir(dir)
end)

T.run()
