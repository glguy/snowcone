local file = require 'pl.file'
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
function M.ask_password(task, label)
    set_input_mode('password', label, task)
    return assert(coroutine.yield(), 'Password aborted')
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
            local input
            if not entry.use_tty then
                input = ''
            end
            local exit_code, stdout, stderr = task:execute(entry.command, entry.arguments, input)
            if exit_code == 0 then
                if entry.multiline then
                    return stdout
                else
                    return (stdout:match '^[^\n]*')
                end
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
        elseif entry.file then
            return assert(file.read(M.resolve_path(entry.file)))
        end
    end

    error('Bad password entry: ' .. tostring(entry))
end

-- return the first credential that matches the name
-- name defaults
function M.get_credential(credentials, name)
    for _, credential in ipairs(credentials) do
        if (credential.name or credential.mechanism) == name then
            return credential
        end
    end
end

return M
