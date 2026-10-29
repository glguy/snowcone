-- Module loader and the reload procedure.
--
-- Every reload makes a new generation with its own module cache, so the new
-- code loads beside the old code and replaces it only once all of it has
-- loaded. Penlight and native libraries go through the real `require` and
-- are shared by all generations.

local M = {}

local prefix <const> = 'hub.'

--- Make a fresh module cache rooted at the hub directory.
---@param root string directory holding init.lua
---@param overrides table<string, string|function>|nil source or chunk by module name
---@return hub.Generation
function M.new_generation(root, overrides)
    ---@class hub.Generation
    ---@field root string
    ---@field loaded table<string, any> results of the modules required so far
    ---@field env table the environment every module runs in
    local gen = {root = root, loaded = {}}
    overrides = overrides or {}

    -- One environment serves every module of the generation. It reads
    -- through to _G and refuses new globals, so a stray assignment fails
    -- at runtime as well as in luacheck.
    local env = setmetatable({}, {
        __index = _G,
        __newindex = function(_, k)
            error('assignment to undeclared global: ' .. tostring(k), 2)
        end,
    })

    local loading <const> = {}

    ---@param name string
    ---@return any ...
    function gen.require(name)
        if name:sub(1, #prefix) ~= prefix then
            return require(name)
        end

        local m = gen.loaded[name]
        if m ~= nil then return m end
        if loading[name] then
            error('circular require: ' .. name, 2)
        end

        local chunk
        local override = overrides[name]
        if type(override) == 'function' then
            chunk = override
        else
            local rel = name:sub(#prefix + 1):gsub('%.', '/')
            local filename = root .. '/' .. rel .. '.lua'
            local source = override
            local err
            if source then
                chunk, err = load(source, '=' .. filename, 't', env)
            else
                -- hub.x is x.lua, or x/init.lua for a directory
                local f = io.open(filename)
                if f then
                    f:close()
                else
                    filename = root .. '/' .. rel .. '/init.lua'
                end
                chunk, err = loadfile(filename, 't', env)
            end
            if not chunk then error(err, 0) end
        end

        loading[name] = true
        local ok, result = pcall(chunk, name)
        loading[name] = nil
        if not ok then error(result, 0) end
        if result == nil then result = true end
        gen.loaded[name] = result
        return result
    end

    rawset(env, 'require', gen.require)
    gen.env = env
    return gen
end

--- Options of reload. The first load's ui, tick, strict, echo, args,
--- config and transport are kept in HUB.boot for later reloads; overrides,
--- modules and config apply to the one load.
---@class hub.ReloadOptions
---@field init string|nil path of init.lua (default: arg[0]), read by init.lua
---@field root string|nil the hub directory (default: the directory of init)
---@field ui boolean|nil false runs without a terminal (default: ncurses is present)
---@field tick boolean|nil false skips the 1 Hz timer (default: same as ui)
---@field strict boolean|nil true re-raises errors from routes and subscribers
--- after logging them, so headless tests fail (a failed reload still just
--- returns false)
---@field echo boolean|nil true prints log lines to stdout
---@field args string[]|nil command line arguments for configuration (default: arg)
---@field config table|nil raw configuration table to use instead of reading a file
---@field transport {connect: fun(...): snowcone.Connection}|nil replaces snowcone.connect
---@field overrides table<string, string|function>|nil source or chunk by module
--- name, replacing files on disk
---@field modules string[]|nil extra module names loaded after the standard ones

---@class hub.Boot
---@field root string
---@field init string path of init.lua
---@field ui boolean
---@field tick boolean
---@field strict boolean
---@field echo boolean
---@field args string[]
---@field config table|nil
---@field transport {connect: fun(...): snowcone.Connection}|nil

--- The one global, which survives reloads.
---@class hub.Root
---@field state hub.State
---@field resources table native handles (runtime/resources.lua)
---@field tasks table<integer, hub.Task> live tasks by id
---@field current hub.Current|nil the active generation
---@field generation integer id of the active generation
---@field boot hub.Boot
---@field task_next_id integer|nil
---@field tty_suspended integer|nil children holding the terminal
---@field dirty boolean|nil the screen needs drawing
---@field defer_draw boolean|nil
---@field entry_installed boolean|nil
---@field errors {total: integer, by_origin: table<string, integer>}|nil
---@field last_reload {at: integer, ok: boolean, error: string|nil}|nil
---@field plugins_started string[]|nil
---@field quitting boolean|nil
---@field shut_down boolean|nil

--- Load a new generation and make it current, or leave the old one running.
---@param root string the hub directory
---@param init string path of init.lua
---@param app string name of the module that builds a generation
---@param opts hub.ReloadOptions
---@return boolean ok
---@return string|nil error
function M.reload(root, init, app, opts)
    ---@type hub.Root
    HUB = HUB or {
        state = nil,
        resources = {},
        tasks = {},
        current = nil,
        generation = 0,
    }

    if not HUB.boot then
        local ui = opts.ui
        if ui == nil then ui = ncurses ~= nil end
        local tick = opts.tick
        if tick == nil then tick = ui end
        HUB.boot = {
            root = root,
            init = init,
            ui = ui,
            tick = tick,
            strict = opts.strict or false,
            echo = opts.echo or false,
            args = opts.args or arg or {},
            -- raw configuration instead of a file, and a fake transport (tests)
            config = opts.config,
            transport = opts.transport,
        }
    end

    local first <const> = HUB.current == nil
    local gen <const> = M.new_generation(root, opts.overrides)
    -- errors raised at level 0, such as configuration errors, need no traceback
    local traceback <const> = gen.require 'hub.lib.traceback'

    local ok, new = xpcall(function()
        return gen.require(app).build(gen, opts)
    end, traceback)

    if not ok then
        local old = HUB.current
        if old then
            -- the old generation keeps running and reports the failure
            old.routes['app.reload_failed'](new)
            return false, new
        end
        -- Nothing is running to show the error; let the client report it
        snowcone.shutdown()
        error(new, 0)
    end

    HUB.generation = HUB.generation + 1
    new.id = HUB.generation
    HUB.current = new
    local activated, err = xpcall(new.routes['app.activate'], traceback, first)
    if not activated then
        new.routes['app.reload_failed'](err)
        return false, err
    end
    return true
end

return M
