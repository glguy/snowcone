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
---@param overrides table|nil [module name] = source string or chunk function
function M.new_generation(root, overrides)
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

--- Load a new generation and make it current, or leave the old one running.
---
--- opts on the first load (kept in HUB.boot for later reloads):
---   ui      false runs without a terminal (default: ncurses is present)
---   tick    false skips the 1 Hz timer (default: same as ui)
---   strict  true re-raises errors from routes and subscribers after
---           logging them, so headless tests fail (a failed reload still
---           just returns false)
---   echo    true prints log lines to stdout
---   args    command line arguments for configuration (default: arg)
---   config  raw configuration table to use instead of reading a file
---   transport  {connect = f} replacing snowcone.connect
--- opts on any load (this generation only):
---   overrides  [module name] = source or chunk, replacing files on disk
---   modules    extra module names loaded after the standard ones
---   config     raw configuration for this load only
---@param app string name of the module that builds a generation
---@return boolean ok
---@return string|nil error message
function M.reload(root, init, app, opts)
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
