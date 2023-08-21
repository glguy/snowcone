-- Library imports
local tablex = require 'pl.tablex'
local pretty = require 'pl.pretty'
local path   = require 'pl.path'
local file   = require 'pl.file'
local app    = require 'pl.app'

if not uptime then
    require 'pl.stringx'.import()
    app.require_here()
end

addstr = ncurses.addstr
mvaddstr = ncurses.mvaddstr

function normal()       ncurses.attrset(ncurses.WA_NORMAL, 0)   end
function bold()         ncurses.attron(ncurses.WA_BOLD)         end
function bold_()        ncurses.attroff(ncurses.WA_BOLD)        end
function italic()       ncurses.attron(ncurses.WA_ITALIC)       end
function italic_()      ncurses.attroff(ncurses.WA_ITALIC)      end
function reversevideo() ncurses.attron(ncurses.WA_REVERSE)      end
function reversevideo_()ncurses.attroff(ncurses.WA_REVERSE)     end
function underline()    ncurses.attron(ncurses.WA_UNDERLINE)    end
function underline_()   ncurses.attroff(ncurses.WA_UNDERLINE)   end
function red()          ncurses.colorset(ncurses.red)           end
function green()        ncurses.colorset(ncurses.green)         end
function blue()         ncurses.colorset(ncurses.blue)          end
function cyan()         ncurses.colorset(ncurses.cyan)          end
function black()        ncurses.colorset(ncurses.black)         end
function magenta()      ncurses.colorset(ncurses.magenta)       end
function yellow()       ncurses.colorset(ncurses.yellow)        end
function white()        ncurses.colorset(ncurses.white)         end

function require_(name)
    package.loaded[name] = nil
    return require(name)
end

-- Local modules ======================================================

local Editor             = require_ 'components.Editor'
local OrderedMap         = require_ 'components.OrderedMap'
local addircstr          = require_ 'utils.irc_formatting'
local send               = require_ 'utils.send'
local irc_registration   = require_ 'utils.irc_registration'
local plugin_manager     = require_ 'utils.plugin_manager'

-- Load configuration =================================================

do
    local config_home = os.getenv 'XDG_CONFIG_HOME'
                     or path.join(assert(os.getenv 'HOME', 'HOME not set'), '.config')
    config_dir = path.join(config_home, 'snowcone')

    local flags = app.parse_args(arg, {config=true})
    local settings_filename = flags.config or path.join(config_dir, 'settings.lua')
    local settings_file = file.read(settings_filename)
    configuration = assert(pretty.read(settings_file))
end

-- Validate configuration =============================================

if not configuration.nick then
    error 'Configuration nick required'
end

if string.match(configuration.nick, '[ \n\r\x00]') then
    error 'Invalid character in nickname'
end

if configuration.user and string.match(configuration.user, '[ \n\r\x00]') then
    error 'Invalid character in username'
end

if configuration.gecos and string.match(configuration.gecos, '[\n\r\x00]') then
    error 'Invalid character in GECOS'
end

if configuration.pass and string.match(configuration.pass, '[\n\r\x00]') then
    error 'Invalid character in server password'
end

if configuration.oper_username and string.match(configuration.oper_username, '[ \n\r\x00]') then
    error 'Invalid character in operator username'
end

-- Global state =======================================================

function reset_filter()
    filter = nil
end

local defaults = {
    -- state
    messages = OrderedMap(1000), -- Raw IRC protocol messages
    buffers = {}, -- [irccase(target)] = {name=string, messages=OrderedMap, seen=number}
    status_messages = OrderedMap(100),
    editor = Editor(),
    view = 'console',
    uptime = 0, -- seconds since startup
    liveness = 0, -- timestamp of last irc receipt
    scroll = 0,
    status_message = '',
    exiting = false,
    terminal_focus = true,
    notification_muted = {},
}

function initialize()
    tablex.update(_G, defaults)
    reset_filter()
end

for k,v in pairs(defaults) do
    if not _G[k] then
        _G[k] = v
    end
end

--  Helper functions ==================================================

function ctrl(x)
    return 0x1f & string.byte(x)
end

function meta(x)
    return -string.byte(x)
end

function status(category, fmt, ...)
    local text = string.format(fmt, ...)
    status_messages:insert(nil, {
        time = os.date("!%H:%M:%S"),
        text = text,
        category = category,
    })
    status_message = text
end

-- Mouse logic ========================================================

local clicks = {}

function add_click(y, lo, hi, action)
    local list = clicks[y]
    local entry = {lo=lo, hi=hi, action=action}
    if list then
        table.insert(list, entry)
    else
        clicks[y] = {entry}
    end
end

function add_button(text, action, plain)
    local y1,x1 = ncurses.getyx()
    if not plain then reversevideo() end
    addstr(text)
    if not plain then reversevideo_() end
    local _, x2 = ncurses.getyx()
    add_click(y1, x1, x2, action)
end

-- Screen rendering ===================================================

local input_mode_palette = {
    command = ncurses.blue,
    talk = ncurses.green,
    filter = ncurses.red,
}

function draw_global_load()
    local titlecolor = ncurses.white

    ncurses.colorset(ncurses.black, titlecolor)
    mvaddstr(tty_height-1, 0, string.format('%-8.8s', view))

    if input_mode then
        local input_mode_color = input_mode_palette[input_mode]
        ncurses.colorset(titlecolor, input_mode_color)
        addstr('')
        ncurses.colorset(ncurses.white, input_mode_color)
        addstr(input_mode)
        ncurses.colorset(input_mode_color)
        addstr('')

        if 1 < editor.first then
            yellow()
            addstr('…')
            ncurses.colorset(input_mode_color)
        else
            addstr(' ')
        end

        if input_mode == 'filter' and not pcall(string.match, '', editor:content()) then
            red()
        end

        local y0, x0 = ncurses.getyx()

        addstr(editor.before_cursor)

        -- cursor overflow: clear and redraw
        local y1, x1 = ncurses.getyx()
        if x1 == tty_width - 1 then
            yellow()
            mvaddstr(y0, x0-1, '…' .. string.rep(' ', tty_width)) -- erase line
            ncurses.colorset(input_mode_color)
            editor:overflow()
            mvaddstr(y0, x0, editor.before_cursor)
            y1, x1 = ncurses.getyx()
        end

        addstr(editor.at_cursor)
        ncurses.move(y1, x1)
        ncurses.cursset(1)
    else
        ncurses.colorset(titlecolor)
        addstr('')
        normal()

        views[view]:draw_status()

        if status_message then
            addircstr(' ' .. status_message)
        end

        if scroll ~= 0 then
            addstr(string.format(' SCROLL %d', scroll))
        end

        if filter ~= nil then
            yellow()
            addstr(' FILTER ')
            normal()
            addstr(string.format('%q', filter))
        end

        add_click(tty_height-1, 0, 9, next_view)
        ncurses.cursset(0)
    end
end

views = {
    stats = require_ 'view.stats',
    console = require_ 'view.console',
    status = require_ 'view.status',
    plugins = require_ 'view.plugins',
    help = require_ 'view.help',
    bouncer = require_ 'view.bouncer',
    buffer = require_ 'view.buffer',
    session = require_ 'view.session',
}

main_views = {'console', 'status'}

function next_view()
    local current = tablex.find(main_views, view)
    if current then
        view = main_views[current % #main_views + 1]
    else
        view = main_views[1]
    end
end

function prev_view()
    local current = tablex.find(main_views, view)
    if current then
        view = main_views[(current - 2) % #main_views + 1]
    else
        view = main_views[1]
    end
end

function draw()
    clicks = {}
    ncurses.erase()
    normal()
    views[view]:render()
    ncurses.refresh()
end

-- Timers =============================================================

if not tick_timer then
    tick_timer = snowcone.newtimer()
    local function cb()
        tick_timer:start(1000, cb)
        uptime = uptime + 1
        if irc_state and irc_state.phase == 'connected' and uptime == liveness + 30 then
            send('PING', string.format('snowcone-%d', uptime))
        end
        draw()
    end
    tick_timer:start(1000, cb)
end

function disconnect(msg)
    if send_irc then
        send('QUIT', msg)
        send_irc()
        send_irc = nil
    end
end

function quit(msg)
    if tick_timer then
        tick_timer:stop()
        tick_timer = nil
    end
    if reconnect_timer then
        reconnect_timer:stop()
        reconnect_timer = nil
    end
    if send_irc then
        exiting = true
        disconnect(msg)
    else
        if not exiting then
            exiting = true
            snowcone.shutdown()
        end
    end
end

-- Command handlers ===================================================

commands = require_ 'handlers.commands'

-- Load plugins

plugin_manager.startup()


-- Callback Logic =====================================================

local M = {}

local key_handlers = require_ 'handlers.keyboard'
local input_handlers = require_ 'handlers.input'
function M.on_keyboard(key)
    -- buffer text editing
    if input_mode and 0x20 <= key and (key < 0x7f or 0xa0 <= key) then
        editor:add(key)
        draw()
        return
    end

    if input_mode then
        local f = input_handlers[key]
        if f then
            f()
            draw()
            return
        end
    end

    -- view-specific key handlers - return true to consume event
    if views[view]:keypress(key) then
        return
    end

    -- global key handlers
    local f = key_handlers[key]
    if f then
        f()
        draw()
        return
    end
end

function M.on_paste(paste)
    if input_mode then
        for _, c in utf8.codes(paste) do
            -- paste up to the first newline or nul
            if c == 0 or c == 10 or c == 13 then
                break
            end
            editor:add(c)
        end
        draw()
    end
end

function M.on_mouse(y, x)
    for _, button in ipairs(clicks[y] or {}) do
        if button.lo <= x and x < button.hi then
            button.action()
            draw()
        end
    end
end

function M.print(str)
    status('print', '%s', str)
end

function M.on_resize()
    draw()
end

snowcone.setmodule(M)

local connect

-- a global allows these to be replaced on a live connection
irc_handlers = require_ 'handlers.irc'

local function on_irc(event, irc)
    if event == 'message' then
        do
            local time_tag = irc.tags.time
            irc.time = time_tag and string.match(irc.tags.time, '^%d%d%d%d%-%d%d%-%d%dT(%d%d:%d%d:%d%d)%.%d%d%dZ$')
                    or os.date '!%H:%M:%S'
        end
        irc.timestamp = uptime

        messages:insert(true, irc)
        liveness = uptime

        -- Ignore chat history
        local batch = irc_state.batches[irc.tags.batch]
        if batch then
            local n = batch.n + 1
            batch.n = n
            batch.messages[n] = irc
            return
        end

        local f = irc_handlers[irc.command]
        if f then
            local success, message = pcall(f, irc)
            if not success then
                status('irc', 'irc handler error: %s', message)
            end
        end

        for _, plugin in pairs(plugins) do
            local h = plugin.irc
            if h then
                local success, result = pcall(h, irc)
                if not success then
                    status(plugin.name, 'irc handler error: %s', result)
                end
            end
        end

        draw()
    elseif event == 'connect' then
        send_irc = irc
        if exiting then
            disconnect()
        else
            irc_registration()
        end
    elseif event == 'closed' then
        irc_state = nil
        send_irc = nil
        status('irc', 'disconnected: %s', irc or 'end of stream')

        if exiting then
            snowcone.shutdown()
        else
            reconnect_timer = snowcone.newtimer()
            reconnect_timer:start(1000, function()
                reconnect_timer = nil
                connect()
            end)
        end
        return
    elseif event == 'bad message' then
        status('irc', 'message parse error: %d', irc)
    end
end

-- declared above so that it's in scope in on_irc
function connect()
    local success, result = pcall(
        snowcone.connect,
        configuration.tls,
        configuration.host,
        configuration.port,
        configuration.tls_client_cert,
        configuration.tls_client_key,
        configuration.tls_client_password,
        configuration.tls_verify_host,
        on_irc)
    if success then
        status('irc', 'connecting')
    else
        status('irc', 'failed to connect: %s', result)
    end
end

if not send_irc and configuration.host and configuration.port then
    connect()
end
