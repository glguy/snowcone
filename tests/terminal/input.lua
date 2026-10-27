-- Records the client's input callbacks for tests-terminal, one line per
-- event on descriptor 3. ^D shuts down.
--
--   char a          a key with a printable character
--   key 13          any other character, by code point
--   key KEY_UP      a curses key, by name
--   alt a           Alt with a printable character
--   paste 5 hello   a paste: its length, then its text with anything but
--                   printable ASCII as \xHH (only the ends past 64 bytes)
--   discarded 70006 a paste over the limit, by size
--   mouse 3 10 false
--   resize 100 30   after SIGWINCH: tty_width, tty_height

local out = assert(io.open('/dev/fd/3', 'w'))
out:setvbuf 'line'

local function emit(...)
    local fields = table.pack(...)
    for i = 1, fields.n do fields[i] = tostring(fields[i]) end
    out:write(table.concat(fields, ' '), '\n')
end

local function show(text)
    local function escape(s)
        return (s:gsub('.', function(c)
            local b = c:byte()
            if b <= 0x20 or b >= 0x7f or c == '\\' then
                return string.format('\\x%02x', b)
            end
        end))
    end
    if #text <= 64 then return escape(text) end
    return escape(text:sub(1, 8)) .. '...' .. escape(text:sub(-8))
end

local function printable(c)
    return c > 0x20 and c ~= 0x7f and not (0x80 <= c and c < 0xa0)
end

local names = {}

snowcone.setmodule(function(event, ...)
    if event == 'on_keyboard' then
        local key = ...
        if key == 4 then
            snowcone.shutdown()
        elseif key >= 0 then
            if printable(key) then emit('char', utf8.char(key)) else emit('key', key) end
        elseif names[-key] then
            emit('key', names[-key])
        elseif -key < 0x80 and printable(-key) then
            emit('alt', utf8.char(-key))
        else
            emit('key', key)
        end
    elseif event == 'on_paste' then
        local text, size = ...
        if text then emit('paste', #text, show(text)) else emit('discarded', size) end
    elseif event == 'on_mouse' then
        emit('mouse', ...)
    elseif event == 'on_resize' then
        emit('resize', tty_width, tty_height)
    end
end)

snowcone.start_ui()
for k, v in pairs(ncurses) do
    if k:match '^KEY_' then names[v] = k end
end
emit 'ready'
