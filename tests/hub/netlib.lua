-- Helpers for the network layer's tests: a fake connection to boot on,
-- registration, and ways to drive timers and events by hand.
--
--   local N = dofile(here .. '/netlib.lua')(T)

return function(T)
    -- the network configuration and boot of lib.lua
    local network = T.network
    local boot = T.boot_networks

    local function rec(id)
        return HUB.state.nets[id or 'test']
    end

    local function manager()
        return T.require 'hub.net.manager'
    end

    -- Events of one topic, recorded from now on
    local function record(topic)
        local seen = {}
        local bus = T.require 'hub.runtime.bus'
        bus.on(HUB.current.bus, topic, 'test', function(ev) table.insert(seen, ev) end)
        return seen
    end

    -- Drive registration without CAP support beyond LS
    local function register(c, nick, isupport)
        nick = nick or 'me'
        c:con()
        c:recv ':srv CAP * LS :multi-prefix'
        c:recv(':srv CAP ' .. nick .. ' ACK :multi-prefix')
        c:recv(':srv 001 ' .. nick .. ' :Welcome')
        c:recv(':srv 005 ' .. nick .. ' ' .. (isupport or 'CHANTYPES=#') .. ' :are supported')
        c:recv(':srv 376 ' .. nick .. ' :End of MOTD')
    end

    -- Fire a scheduled reconnect now instead of waiting for its timer
    local function fire_reconnect(id)
        local r = rec(id)
        T.ok(r.reconnect_timer, 'reconnect scheduled for ' .. id)
        T.require 'hub.runtime.timer'.cancel(r.reconnect_timer)
        HUB.current.routes['net.reconnect'](id, r.attempt)
    end

    -- Stop the clock for the current generation; returns a function that
    -- moves it on by seconds. It stops on a whole second, never before the
    -- time it shows now, so whole seconds added to it are exact.
    local function stop_clock()
        local clock = T.require 'hub.runtime.clock'
        local now = math.ceil(clock.now()) + 0.0
        clock.now = function() return now end
        return function(seconds) now = now + seconds end
    end

    -- Register with labeled-response, which needs batch
    local function register_labeled(c)
        c:con()
        c:recv ':srv CAP * LS :batch labeled-response'
        c:recv ':srv CAP me ACK :batch labeled-response'
        c:recv ':srv 001 me :Welcome'
        c:recv ':srv 376 me :End of MOTD'
        c:take()
    end

    -- Start a request task that collects the commands it iterates over
    local function requester(commands, timeout_ms, ...)
        local task = T.require 'hub.runtime.task'
        local result = {}
        local args = table.pack(...)
        task.spawn('requester', {net = 'test'}, function(t)
            for msg in t:request(commands, timeout_ms, table.unpack(args, 1, args.n)) do
                table.insert(result, msg.command .. ' ' .. msg[2])
                if msg.command == 318 then break end -- needed without labels
            end
            result.done = true
        end)
        return result
    end

    return {
        network = network,
        boot = boot,
        rec = rec,
        manager = manager,
        record = record,
        register = register,
        fire_reconnect = fire_reconnect,
        stop_clock = stop_clock,
        register_labeled = register_labeled,
        requester = requester,
    }
end
