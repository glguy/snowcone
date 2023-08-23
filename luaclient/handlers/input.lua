-- input mode key handlers

local send = require_ 'utils.send'

local execute = {}

function execute.filter()
    filter = editor:content()
    if filter == '' then
        filter = nil
    end
    editor:reset()
    input_mode = nil
end

function execute.talk()
    local msg = editor:content()
    if msg ~= '' then
        send('PRIVMSG', talk_target, editor:content())
    end
    editor:reset()
    input_mode = nil
end

function execute.command()
    local text = editor:content()
    input_mode = nil

    -- ignore whitespace commands
    if text:match '^%s*$' then
        editor:reset()
        return
    else
        editor:confirm()
    end

    local command, args = text:match '^ *(%g*) *(.*)$'

    local entry = commands[command]
    if not entry then
        for _, plugin in pairs(plugins) do
            entry = plugin.commands[command]
            if entry then break end
        end
    end

    if entry then
        input_mode = nil
        status_message = nil

        local params = {}
        if entry.pattern(args, params) then
            local success, message = pcall(entry.func, table.unpack(params))
            if not success then
                status('error', '%s', message)
            end
        else
            status('error', '%s requires: %s', command, entry.spec)
        end
    else
        status('error', 'unknown command: %s', command)
    end
end

local function do_tab(dir)
    local handler
    if input_mode == 'command' then
        function handler(prefix, seed)
            local t = {}

            if prefix == '' then
                -- Command handlers
                for k, _ in pairs(commands) do
                    if k:startswith(seed) then
                        table.insert(t, k)
                    end
                end
                -- Plugin command handlers
                for _, plugin in pairs(plugins) do
                    if plugin.commands then
                        for k, _ in pairs(plugin.commands) do
                            if k:startswith(seed) then
                                table.insert(t, k)
                            end
                        end
                    end
                end
            else
                -- Channel names
                for _, channel in pairs(irc_state.channels) do
                    if channel.name:startswith(seed) then
                        table.insert(t, channel.name)
                    end
                end
                -- Nicknames in current channel
                if talk_target and irc_state:is_channel_name(talk_target) then
                    local channel = irc_state:get_channel(talk_target)
                    if channel then
                        for _, member in pairs(channel.members) do
                            if member.user.nick:startswith(seed) then
                                table.insert(t,member.user.nick)
                            end
                        end
                    end
                end
            end
            if next(t) then
                table.sort(t)
                return 1, t
            end
        end
    else
        function handler(_, seed)
            local t = {}
            -- Channel names
            for _, channel in pairs(irc_state.channels) do
                if channel.name:startswith(seed) then
                    table.insert(t, channel.name)
                end
            end
            -- Nicknames in current channel
            if talk_target and irc_state:is_channel_name(talk_target) then
                local channel = irc_state:get_channel(talk_target)
                if channel then
                    for _, member in pairs(channel.members) do
                        if member.user.nick:startswith(seed) then
                            table.insert(t,member.user.nick)
                        end
                    end
                end
            end
            if next(t) then
                table.sort(t)
                return 1, t
            end
        end
    end

    if handler then
        editor:tab(dir, handler)
    end
end

return {
    [0x7f                  ] = function() editor:backspace() end, -- Del
    [ctrl 'M'              ] = function() execute[input_mode]() end, -- Enter
    [ctrl 'U'              ] = function() editor:kill_to_beg() end,
    [ctrl 'K'              ] = function() editor:kill_to_end() end,
    [ctrl 'A'              ] = function() editor:move_to_beg() end,
    [ctrl 'E'              ] = function() editor:move_to_end() end,
    [ctrl 'W'              ] = function() editor:kill_prev_word() end,
    [meta 'd'              ] = function() editor:kill_next_word() end,
    [ctrl 'B'              ] = function() editor:move_left() end,
    [ctrl 'F'              ] = function() editor:move_right() end,
    [ctrl 'Y'              ] = function() editor:paste() end,
    [ctrl 'T'              ] = function() editor:swap() end,
    [meta 'f'              ] = function() editor:move_next_word() end,
    [meta 'b'              ] = function() editor:move_prev_word() end,
    [-ncurses.KEY_LEFT     ] = function() editor:move_left() end,
    [-ncurses.KEY_RIGHT    ] = function() editor:move_right() end,
    [-ncurses.KEY_HOME     ] = function() editor:move_to_beg() end,
    [-ncurses.KEY_END      ] = function() editor:move_to_end() end,
    [-ncurses.KEY_BACKSPACE] = function() editor:backspace() end,
    [-ncurses.KEY_DC       ] = function() editor:delete() end,
    [-ncurses.KEY_UP       ] = function() editor:older_history() end,
    [-ncurses.KEY_DOWN     ] = function() editor:newer_history() end,
    [ctrl 'I']               = function() return do_tab(1) end,
    [-ncurses.KEY_BTAB]      = function() return do_tab(-1) end,
}
