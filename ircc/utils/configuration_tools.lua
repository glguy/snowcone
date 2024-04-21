local await = require 'utils.await'
local path = require 'pl.path'

local M = {}

function M.resolve_path(entry)
    -- no path provided in configuration file
    if entry == nil then
        return nil
    end

    -- absolute paths are preserved
    if path.isabs(entry) then
        return entry
    end

    -- relative paths are resolved relative to the configuration directory
    return path.join(config_dir, entry)
end

function M.resolve_password(entry)

    local t = type(entry)

    if t == 'nil' then
        return nil
    end

    if t == 'string' then
        return entry
    end

    if t == 'table' then
        local exit_code, stdout, stderr = await(snowcone.execute, entry.command, entry.arguments or {})
        if exit_code == 0 then
            return (stdout:match '^[^\n]*')
        else
            error('Password command failed: ' .. stderr)
        end
    end

    error('Bad password entry: ' .. tostring(entry))
end

return M