-- Resolving secrets from configuration (from ircc's
-- utils/configuration_tools.lua). A secret is one of:
--   "text"                                     used as is
--   {file = path}                              file contents
--   {command = c, arguments = {...},
--    multiline = bool, use_tty = bool}         a program's output
--   {prompt = label}                           asked for in the UI
-- Resolution runs inside a task, since commands and prompts suspend it.
-- Resolved values are never stored in HUB.state.

local file   <const> = require 'pl.file'
local config <const> = require 'hub.runtime.config'

local M = {}

--- Resolve one secret; nil stays nil.
---@param t table task
---@param entry any
---@return string|nil
function M.resolve(t, entry)
    local kind = type(entry)

    if kind == 'nil' or kind == 'string' then
        return entry
    end

    if kind == 'table' then
        if entry.command then
            local input
            if not entry.use_tty then
                input = ''
            end
            local exit_code, stdout, stderr = t:execute(entry.command, entry.arguments, input)
            if exit_code == 0 then
                if entry.multiline then
                    return stdout
                else
                    return (stdout:match '^[^\n]*')
                end
            elseif exit_code then
                error('command failed (' .. exit_code .. '): ' .. stderr, 0)
            else
                error('execute failed: ' .. tostring(stdout), 0)
            end
        elseif entry.prompt then
            local answer = t:prompt(entry.prompt)
            if answer then
                return answer
            end
            error('prompt aborted', 0)
        elseif entry.file then
            local filename = config.resolve_path(entry.file)
            local text, err = file.read(filename)
            if not text then
                error(err or ('failed to read ' .. filename), 0)
            end
            return text
        end
    end

    error('Bad secret entry: ' .. tostring(entry), 0)
end

--- The first credential with a given name; a credential's name defaults to
--- its mechanism.
function M.get_credential(credentials, name)
    for _, credential in ipairs(credentials or {}) do
        if (credential.name or credential.mechanism) == name then
            return credential
        end
    end
end

--- The PASS password for a server section, with `username:` prepended
--- when a username is configured.
---@return string|nil
function M.server_password(t, server)
    local password = M.resolve(t, server.password)
    if password and server.username then
        password = server.username .. ':' .. password
    end
    return password
end

return M
