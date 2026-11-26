-- A stand-in for snowcone.connect.
--
--   local fake = FakeTransport.new()
--   T.boot {transport = fake, config = ...}
--   local c = fake.last()
--   c:con()                          -- connection established
--   c:con {{type = 'tls', key = k}}  -- after these layers, from 1
--   c:recv ':srv 001 me :Welcome'    -- a line from the server
--   c:take()                         -- lines sent since the last take
--   c:finish('reset')                -- connection ended

local M = {}

function M.new()
    local fake = {conns = {}}

    function fake.connect(host, port, layers, cb)
        local c = {host = host, port = port, layers = layers, cb = cb, sent = {}, closed = false}
        local handle = {}
        function handle:send(raw)
            assert(raw:sub(-2) == '\r\n', 'line without CRLF')
            table.insert(c.sent, raw:sub(1, -3))
        end
        function handle:close()
            c.closed = true
        end

        function c:progress(step, text, info)
            self.cb('PROGRESS', step, text, info)
        end
        function c:con(layers)
            for i, info in ipairs(layers or {}) do
                info.layer = i
                self:progress('done', info.type, info)
            end
            self.cb('CON')
        end
        --- Deliver one line; flush is false for all but the last of a read.
        function c:recv(line, flush)
            self.cb('MSG', snowcone.parse_irc(line), flush ~= false)
        end
        function c:finish(err)
            self.cb('END', err)
        end
        function c:take()
            local sent = self.sent
            self.sent = {}
            return sent
        end

        table.insert(fake.conns, c)
        return handle
    end

    function fake.last()
        return fake.conns[#fake.conns]
    end

    return fake
end

return M
