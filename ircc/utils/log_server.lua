local scrub <const> = require 'utils.scrub'

local M = {}

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
    ['^/index.html$'] = function()
        local reply = {'<ul>'}
        local i = 1
        for k in pairs(buffers) do
            i = i + 1
            reply[i] = '<li><a href="/buffer/' .. urlencode(k) .. '.txt">' .. htmlencode(k) .. '</a>'
        end
        i = i + 1
        reply[i] = '</ul>'
        return 'text/html', html(table.concat(reply))
    end,

    ['^/buffer/(.*)%.txt$'] = function(name)
        name = urldecode(name)
        local buffer = buffers[snowcone.irccase(name)]
        if not buffer then
            error('no such buffer: ' .. name)
        end

        local reply = {}
        local i = 0
        for irc in buffer.messages:reveach() do
            if irc.command == 'PRIVMSG' or irc.command == 'NOTICE' then
                i = i + 1
                reply[i] =  '<' .. irc.nick .. '> ' .. scrub(irc[2]) .. '\n'
            end
        end
        return 'text/plain; charset=utf-8', table.concat(reply)
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
end

function M.stop()
    server:close()
end

return M
