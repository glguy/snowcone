-- Resolving secrets from configuration. A secret is one of:
--   "text"                                     used as is
--   {file = path}                              file contents
--   {command = c, arguments = {...},
--    multiline = bool, use_tty = bool}         a program's output
--   {prompt = label}                           asked for in the UI
-- A private key may instead be {store = name}, a key in an OpenSSL store,
-- which key_store gives and resolve refuses.
-- Resolution runs inside a task, since commands and prompts suspend it.
-- Resolved values are never stored in HUB.state. A task can resolve the
-- secrets it will need ahead of time (prepare), such as registration's
-- before the connection opens; they are kept with the task until it ends.

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

local resolve

--- Resolve one secret; nil stays nil. A secret the task prepared gives
--- what it resolved to then, or its error.
---@param t hub.Task
---@param entry hub.Secret|nil
---@return string|nil
function M.resolve(t, entry)
    local prepared = t.secrets and t.secrets[entry]
    if prepared then
        if prepared.ok then return prepared.value end
        error(prepared.err, 0)
    end
    return resolve(t, entry)
end

--- Resolve secrets now, for the task to use later.
---@param t hub.Task
---@param entries (hub.Secret|false)[] false for a secret not configured
function M.prepare(t, entries)
    t.secrets = t.secrets or {}
    for _, entry in ipairs(entries) do
        if type(entry) == 'table' and not t.secrets[entry] then
            local ok, value = pcall(resolve, t, entry)
            t.secrets[entry] = ok and {ok = true, value = value} or {ok = false, err = value}
        end
    end
end

function resolve(t, entry)
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
            -- a file's last line ends with a line break; the secret doesn't
            return (text:gsub('\r?\n$', '', 1))
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
