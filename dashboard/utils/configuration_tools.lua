local path = require 'pl.path'

local M = {}

--- func desc
---@param entry string | nil
---@return string | nil
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

--- Get a password using an input mode
---@param task any
---@param label string
---@return string
function M.ask_password()
    error("ask password not implemented in dashboard mode")
end

function M.resolve_password(task, entry)

    local t = type(entry)

    if t == 'nil' then
        return nil
    end

    if t == 'string' then
        return entry
    end

    if t == 'table' then
        if entry.command then
            local exit_code, stdout, stderr = task:execute(entry.command, entry.arguments)
            if exit_code == 0 then
                return (stdout:match '^[^\n]*')
            else
                error('Password command failed: ' .. stderr)
            end
        elseif entry.prompt then
            local password = M.ask_password(task, entry.prompt)
            if password then
                return password
            else
                error('Password prompt failed')
            end
        end
    end

    error('Bad password entry: ' .. tostring(entry))
end

return M
