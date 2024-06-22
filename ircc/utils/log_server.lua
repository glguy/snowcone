local scrub <const> = require 'utils.scrub'
local tablex <const> = require 'pl.tablex'

local M <const> = {}

local server

local function html(body)
    return [[<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Snowcone</title></head><body>]] ..
body .. [[</body></html>
]]
end

local function urlencode(str)
    return (str:gsub('[^a-zA-Z0-9]', function(c)
        return string.format('%%%02x', string.byte(c))
    end))
end

local function urldecode(str)
    return (str:gsub('%%(%x%x)', function(c)
        return string.char('0x'..c)
    end))
end

local function htmlencode(str)
    local entities = {
        ['<'] = '&lt;',
        ['>'] = '&gt;',
    }
    return (str:gsub('[<>]', entities))
end

local routes = {
    ['^/$'] = function()
        local reply = {'<ul><li><a href="/status.html">Status</a><li><a href="/console.html">Console</a>'}
        local i = 1
        for k in tablex.sort(buffers) do
            i = i + 1
            reply[i] = '<li><a href="/buffer/' .. urlencode(k) .. '.txt">' .. htmlencode(k) .. '</a>'
        end
        i = i + 1
        reply[i] = '</ul>'
        return 'text/html', html(table.concat(reply))
    end,

    ['^/status.html$'] = function()
        local reply = {'<p><a href="/">Index</a></p><table>'}
        local i = 1
        for entry in status_messages:reveach() do
            i = i + 1
            reply[i] =
                '<tr><td>' .. entry.time .. '</td><td>' .. htmlencode(entry.category) ..
                '</td><td>' .. htmlencode(entry.text) .. '</td></tr>'
        end
        i = i + 1
        reply[i] = '</table>'
        return 'text/html; charset=utf-8', html(table.concat(reply))
    end,

    ['^/console.html$'] = function()
        local reply = {'<p><a href="/">Index</a></p><table>'}
        local i = 1
        for irc in messages:reveach() do
            local n = #irc
            local raw
            if n == 0 then
                raw = irc.command
            elseif not (irc[n]:startswith ':' or irc[n]:match ' ') then
                raw = irc.command .. ' ' .. table.concat(irc, ' ')
            elseif n > 1 then
                raw = irc.command .. ' ' .. table.concat(irc, ' ', 1, n-1) .. ' :' .. irc[n]
            else
                raw = irc.command .. ' :' .. irc[n]
            end
            i = i + 1
            reply[i] =
                '<tr><td>' .. irc.time .. '</td><td>' ..
                htmlencode(scrub(raw)) ..
                '</td></tr>'
        end
        i = i + 1
        reply[i] = '</table>'
        return 'text/html; charset=utf-8', html(table.concat(reply))
    end,

    ['^/buffer/(.*)%.txt$'] = function(name)
        name = urldecode(name)
        local buffer = buffers[snowcone.irccase(name)]
        if not buffer then
            error('no such buffer: ' .. name)
        end

        local reply = {'<p><a href="/">Index</a></p><pre>'}
        local i = 1
        for irc in buffer.messages:reveach() do
            if irc.command == 'PRIVMSG' or irc.command == 'NOTICE' then
                i = i + 1
                reply[i] =  htmlencode('<' .. irc.nick .. '> ' .. scrub(irc[2]) .. '\n')
            end
        end
        i = i + 1
        reply[i] = '</pre>'
        return 'text/html; charset=utf-8', html(table.concat(reply))
    end,
}

local function handler(method, path, err)
    if method == nil then
        status('httpd', '%s: %s', path, err)
        return
    end

    if method ~= 'GET' then
        error 'bad method'
    end

    for k, v in pairs(routes) do
        local matches = {path:match(k)}
        if matches[1] then
            return v(table.unpack(matches))
        end
    end

    error 'no such route'
end

function M.start(port)
    server = snowcone.start_httpd(port, handler)
    background_resources[server] = 'close'
end

function M.stop()
    server:close()
end

return M
