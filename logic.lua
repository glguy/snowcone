local black   = '\x1b[30m'
local red     = '\x1b[31m'
local green   = '\x1b[32m'
local yellow  = '\x1b[33m'
local blue    = '\x1b[34m'
local magenta = '\x1b[35m'
local cyan    = '\x1b[36m'
local white   = '\x1b[37m'
local reset   = '\x1b[0m'

local function new_ordered_map()
        local sentinel = {}
        sentinel.next = sentinel
        sentinel.prev = sentinel

        local obj = { sentinel = sentinel, index = {}, n=0 }

        local function unlink_node(node)
                local p = node.prev
                local q = node.next
                p.next = q
                q.prev = p
        end

        local function link_after(p, node)
                local q = p.next
                p.next = node
                node.next = q
                q.prev = node
                node.prev = p
        end 

        function obj:first_key()
                if self.n > 0 then
                        return self.sentinel.next.key
                end
        end

        function obj:last_key()
                if self.n > 0 then
                        return self.sentinel.prev.key
                end
        end

        function obj:insert(key, val)
                local node = self.index[key]
                if node then
                        unlink_node(node)
                else
                        node = {key = key, val = val}
                        self.n = self.n + 1
                        self.index[key] = node
                end
                link_after(self.sentinel, node)
                return node.val
        end

        function obj:delete(key)
                local node = self.index[key]
                if not node then return end
                self.index[key] = nil
                self.n = self.n - 1
                unlink_node(node)
        end

        function obj:lookup(key)
                local node = self.index[key]
                if node then
                        return node.val
                end
        end

        local function each_step(obj, prev)
                local node
                if prev then
                        node = obj.index[prev].next
                else 
                        node = obj.sentinel.next
                end
                return node.key, node.val
        end

        function obj:each()
                return each_step, obj
        end

        return obj
end

-- Global state =======================================================

local function initialize()
        users = new_ordered_map()
        initialized = true
        output = nil
        history = 1000
        show_reasons = true
end

if not initialized then
        initialize()
end

-- Screen rendering ===================================================

local function draw()
        io.write('\x1b[2J')

        local n = 0
        for mask, entry in users:each() do
                if not filter or string.match(mask .. ' ' .. entry.gecos, filter) then
                        local txt
                        if entry.connected then
                                txt = green .. mask .. reset
                        else
                                txt = red .. mask .. reset
                        end

                        if show_reasons and not entry.connected then
                                io.write(string.format("%s %4d %-80s %s\n",
                                        cyan .. entry.time .. reset,
                                        entry.count or 1,
                                        txt,
                                        magenta .. (entry.reason or "") .. reset))
                        else
                                io.write(string.format("%s %4d %-80s %-48s %s\n",
                                        cyan .. entry.time .. reset,
                                        entry.count or 1,
                                        txt,
                                        yellow .. entry.ip .. reset,
                                        string.format('%q', entry.gecos)))
                        end
                end
                n = n + 1
                if n >= 30 then break end
        end

        io.write('\n')
        if output then
                print(output)
        end

        if filter then
                print('FILTER: ' .. filter)
        else
                print ('NOFILTER')
        end
end

-- Server Notice parsing ==============================================

local function parse_snote(str)
        local time, nick, userhost, ip, gecos = string.match(str, '^%[([^][]*)%] -%g*- %*%*%* Notice %-%- Client connecting: (%g+) %(([^)]+)%) %[(.*)%] {%?} %[(.*)%]$')
        if nick then
                return {
                        name = 'connect',
                        mask = nick .. '!' .. userhost,
                        ip = ip,
                        gecos = gecos,
                        time = time
                }
        end

        local time, nick, userhost, reason, ip = string.match(str, '^%[([^][]*)%] -%g*- %*%*%* Notice %-%- Client exiting: (%g+) %(([^)]+)%) %[(.*)%] %[([^]]*)%]$')
        if nick then
                return {
                        name = 'disconnect',
                        mask = nick .. '!' .. userhost,
                        reason = reason,
                        ip = ip,
                }
        end
end

-- Server Notice handlers =============================================

local handlers = {}

function handlers.connect(ev)
        local entry = users:insert(ev.mask, {count = 0})
        entry.gecos = ev.gecos
        entry.ip = ev.ip
        entry.time = ev.time
        entry.connected = true
        entry.count = entry.count + 1

        while users.n > history do
                users:delete(users:last_key())
        end
        draw()
end

function handlers.disconnect(ev)
        local entry = users:lookup(ev.mask)
        if entry then
                entry.connected = false
                entry.reason = ev.reason
                draw()
        end
end

-- Callback Logic =====================================================

local M = {}

function M.on_input(str)
        if str == 'clear' then
                initialized = false
                initialize()
                draw()
                return
        end

        if str == 'nofilter' then
                filter = nil
                output = nil
                draw()
                return
        end

        local pattern = string.match(str, '^filter (.*)')
        if pattern then
                filter = pattern
                output = nil
                draw()
                return
        end

        local src = string.match(str, '^>(.*)$')
        if src then
                local chunk, err = load(src, '=(load)', 't')
                if chunk then
                        local success, result = pcall(chunk)
                        output = result
                else
                        output = err
                end
                draw()
                return
        end
        
        output = 'Unknown command'
        draw()
end

function M.on_snote(str)
        local event = parse_snote(str)
        if event then
                local h = handlers[event.name]
                h(event)
        end
end

return M
