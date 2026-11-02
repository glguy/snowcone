-- Resolving secrets from configuration. A secret is one of:
--   "text"                                     used as is
--   {file = path}                              file contents
--   {command = c, arguments = {...},
--    multiline = bool, use_tty = bool}         a program's output
--   {prompt = label}                           asked for in the UI
-- A private key may instead be {store = name}, a key in an OpenSSL store,
-- which key_store gives and resolve refuses.
-- Resolution runs inside a task, since commands and prompts suspend it.
-- Resolved values are never stored in HUB.state.

local file   <const> = require 'pl.file'
local config <const> = require 'hub.runtime.config'

local M = {}

--- A secret in the configuration: the text itself, or where to get it.
---@alias hub.Secret
---| string
---| {command: string, arguments: string[]|nil, use_tty: boolean|nil, multiline: boolean|nil}
---| {prompt: string}
---| {file: string}

--- The store name of a private key given as {store = name}, or nil for
--- a key that is a secret holding its text.
---@param entry hub.Secret|{store: string}|nil
---@return string|nil
function M.key_store(entry)
    return type(entry) == 'table' and entry.store or nil
end

--- Resolve one secret; nil stays nil.
---@param t hub.Task
---@param entry hub.Secret|nil
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

--- The PASS password for a registration section, with `username:` prepended
--- when a username is configured.
---@param t hub.Task
---@param registration {password: hub.Secret|nil, username: string|nil}
---@return string|nil
function M.server_password(t, registration)
    local password = M.resolve(t, registration.password)
    if password and registration.username then
        password = registration.username .. ':' .. password
    end
    return password
end

return M
