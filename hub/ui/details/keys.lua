-- What a crypto command made or read (hub.Keys, commands/crypto.lua) in
-- the detail pane. The services commands are flush left, each on its own
-- row, so they copy cleanly. A private key appears only here.

local draw   <const> = require 'hub.ui.draw'
local fields <const> = require 'hub.ui.fields'
local scrub  <const> = require 'hub.lib.scrub'

local heading <const> = fields.heading
local label   <const> = fields.label

local M = {kind = 'keys'}

function M.title(detail)
    return detail.data.what
end

function M.render(ctx, win)
    ---@type hub.Keys
    local keys = ctx.vs.data

    heading(win, string.format('%s, %s', keys.what, keys.made and 'made' or 'read'))

    if keys.file then
        label(win, 'file')
        win:waddstr(scrub(keys.file), '\n')
    end
    if keys.encrypted ~= nil then
        label(win, 'password')
        win:waddstr(keys.encrypted and 'yes' or 'none', '\n')
    end
    if keys.public then
        label(win, 'public')
        win:waddstr(keys.public, '\n')
    end
    if keys.fingerprint then
        label(win, 'sha512')
        win:waddstr(keys.fingerprint, '\n')
    end
    if keys.private then
        label(win, 'private')
        draw.red(win)
        win:waddstr(keys.private, '\n')
        draw.normal(win)
        label(win, '')
        draw.yellow(win)
        win:waddstr('not saved or logged anywhere: keep it now\n')
        draw.normal(win)
    end

    heading(win, 'Send to services')
    for _, command in ipairs(keys.commands) do
        win:waddstr(command, '\n')
    end
end

return M
