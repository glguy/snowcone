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

-- Clean out local modules to make reloads reload more
do
    local loaded = package.loaded
    for k, _ in pairs(loaded) do
        if k:startswith 'components.'
        or k:startswith 'handlers.'
        or k:startswith 'notification.'
        or k:startswith 'sasl.'
        or k:startswith 'utils.'
        or k:startswith 'view.'
        then
            loaded[k] = nil
        end
    end
end

do
    -- try to avoid a bunch of table lookups
    local attrset = ncurses.attrset
    local attron = ncurses.attron
    local attroff = ncurses.attroff
    local colorset = ncurses.colorset
    local WA_NORMAL = ncurses.WA_NORMAL
    local WA_BOLD = ncurses.WA_BOLD
    local WA_ITALIC = ncurses.WA_ITALIC
    local WA_REVERSE = ncurses.WA_REVERSE
    local WA_UNDERLINE = ncurses.WA_UNDERLINE
    local red_ = ncurses.COLOR_RED
    local green_ = ncurses.COLOR_GREEN
    local blue_ = ncurses.COLOR_BLUE
    local cyan_ = ncurses.COLOR_CYAN
    local black_ = ncurses.COLOR_BLACK
    local magenta_ = ncurses.COLOR_MAGENTA
    local yellow_ = ncurses.COLOR_YELLOW
    local white_ = ncurses.COLOR_WHITE

    function normal(w)        attrset(WA_NORMAL, 0, w)   end
    function bold(w)          attron(WA_BOLD, w)         end
    function bold_(w)         attroff(WA_BOLD, w)        end
    function italic(w)        attron(WA_ITALIC, w)       end
    function italic_(w)       attroff(WA_ITALIC, w)      end
    function reversevideo(w)  attron(WA_REVERSE, w)      end
    function reversevideo_(w) attroff(WA_REVERSE, w)     end
    function underline(w)     attron(WA_UNDERLINE, w)    end
    function underline_(w)    attroff(WA_UNDERLINE, w)   end
    function red(w)           colorset(red_, nil, w)     end
    function green(w)         colorset(green_, nil, w)   end
    function blue(w)          colorset(blue_, nil, w)    end
    function cyan(w)          colorset(cyan_, nil, w)    end
    function black(w)         colorset(black_, nil, w)   end
    function magenta(w)       colorset(magenta_, nil, w) end
    function yellow(w)        colorset(yellow_, nil, w)  end
    function white(w)         colorset(white_, nil, w)   end
end

-- Local modules ======================================================

local drawing             <const> = require 'utils.drawing'
local Editor              <const> = require 'components.Editor'
local Irc                 <const> = require 'components.Irc'
local irc_registration    <const> = require 'utils.irc_registration'
local OrderedMap          <const> = require 'components.OrderedMap'
local plugin_manager      <const> = require 'utils.plugin_manager'
local send                <const> = require 'utils.send'
local Task                <const> = require 'components.Task'
local configuration_tools <const> = require 'utils.configuration_tools'

function reset_filter()
    filter = nil
end

-- Make windows ==================================================

local function make_layout()
    if main_pad then
        main_pad:delwin()
    end
    main_pad = ncurses.newpad(tty_height-1, 550)
    if input_win then
        input_win:delwin()
    end
    input_win = ncurses.newwin(1, tty_width, tty_height - 1, 0)
    textbox_pad = ncurses.newpad(1, 1024)
end
make_layout()

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
        timestamp = uptime,
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

function add_button(win, text, action, plain)
    local y1,x1 = ncurses.getyx(win)
    if not plain then reversevideo(win) end
    win:waddstr(text)
    if not plain then reversevideo_(win) end
    local _, x2 = ncurses.getyx(win)
    add_click(y1, x1, x2, action)
end

-- Screen rendering ===================================================

views = {
    stats = require 'view.stats',
    console = require 'view.console',
    status = require 'view.status',
    plugins = require 'view.plugins',
    help = require 'view.help',
    bouncer = require 'view.bouncer',
    buffer = require 'view.buffer',
    session = require 'view.session',
    channels = require 'view.channels',
}

main_views = {'console', 'status'}

function set_view(v)
    scroll = 0
    hscroll = 0
    view = v
end

function next_view()
    hscroll = 0
    local current = tablex.find(main_views, view)
    if current then
        set_view(main_views[current % #main_views + 1])
    else
        set_view(main_views[1])
    end
end

function prev_view()
    local current = tablex.find(main_views, view)
    if current then
        set_view(main_views[(current - 2) % #main_views + 1])
    else
        set_view(main_views[1])
    end
end

local function draw()
    clicks = {}
    ncurses.erase()
    main_pad:werase()
    input_win:werase()
    textbox_pad:werase()

    normal(main_pad)
    views[view]:render(main_pad)

    drawing.draw_status_bar(input_win, textbox_pad)

    ncurses.noutrefresh()
    main_pad:pnoutrefresh(0, hscroll, 0, 0, tty_height-2, tty_width-1)
    ncurses.noutrefresh(input_win)

    if input_mode then
        local _, ix = ncurses.getyx(input_win)
        textbox_pad:pnoutrefresh(0, textbox_offset, tty_height-1, ix, tty_height-1, tty_width-1)
    end
    ncurses.doupdate()
end

-- Callback Logic =====================================================

local M = {}

local key_handlers = require 'handlers.keyboard'
local input_handlers = require 'handlers.input'
function M.on_keyboard(key)
    -- buffer text editing
    if input_mode and 0x20 <= key and (key < 0x7f or 0xa0 <= key) then
        editor:add(key)
        goto done
    end

    if input_mode then
        local f = input_handlers[key]
        if f then
            f()
            goto done
        end
    end

    -- view-specific key handlers - return true to consume event
    if views[view]:keypress(key) then
        goto done
    end

    -- global key handlers
    do
        local f = key_handlers[key]
        if f then
            f()
            goto done
        end
    end

    ::done::
    draw()
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

function M.on_mouse(y, x, shifted)
    for _, button in ipairs(clicks[y] or {}) do
        if button.lo <= x and x < button.hi then
            button.action(shifted)
            draw()
        end
    end
end

function M.print(str)
    status('print', '%s', str)
end

function M.on_resize()
    make_layout()
    draw()
end

snowcone.setmodule(function(ev, ...)
    M[ev](...)
end)

local function teardown()
    if tick_timer then
        tick_timer:cancel()
        tick_timer = nil
    end
    snowcone.shutdown()
end

local conn_handlers = {}

function connect()

    if not configuration.host then
        status('connect', 'Connect host not specified')
        mode_target = 'idle'
        if mode_current ~= 'idle' then
            mode_current = 'idle'
            mode_timestamp = uptime
        end
        return
    end

    -- the connecting mode isn't interruptible due to wait on external process
    if mode_current == 'idle' then
        mode_current = 'connecting'
        mode_timestamp = uptime
    elseif mode_current == 'connecting' then
        error 'already connecting'
    elseif mode_current == 'connected' then
        error 'already connected'
    else
        error 'PANIC: bad mode_current'
    end

    Task('connect', client_tasks, function(task) -- passwords might need to suspend connecting

        local ok1, tls_client_password =
            pcall(configuration_tools.resolve_password, task, configuration.tls_client_password)
        if not ok1 then
            status('connect', 'TLS client key password program error: %s', tls_client_password)
            mode_current = 'idle' -- exits connecting mode
            mode_timestamp = uptime
            if mode_target == 'connected' then mode_target = 'idle' end -- don't reconnect
            return
        end

        local ok2, socks_password = pcall(configuration_tools.resolve_password, task, configuration.socks_password)
        if not ok2 then
            status('connect', 'SOCKS5 password program error: %s', socks_password)
            mode_current = 'idle' -- exits connecting mode
            mode_timestamp = uptime
            if mode_target == 'connected' then mode_target = 'idle' end -- don't reconnect
            return
        end

        local conn, errmsg =
            snowcone.connect(
            configuration.tls,
            configuration.host,
            configuration.port or configuration.tls and 6697 or 6667,
            configuration_tools.resolve_path(configuration.tls_client_cert),
            configuration_tools.resolve_path(configuration.tls_client_key),
            tls_client_password,
            configuration.tls_verify_host,
            configuration.tls_sni_host,
            configuration.socks_host,
            configuration.socks_port,
            configuration.socks_username,
            socks_password,
            function(event, arg)
                conn_handlers[event](arg)
            end)

        if conn then
            status('irc', 'connecting')
            irc_state = Irc(conn)
            mode_current = 'connected'
            mode_timestamp = uptime
        else
            status('irc', 'failed to connect: %s', errmsg)
            mode_current = 'idle' -- exits connecting mode
            mode_timestamp = uptime
        end
    end)
end

-- a global allows these to be replaced on a live connection
irc_handlers = require 'handlers.irc'

function conn_handlers.FLUSH()
    draw()
end

function conn_handlers.MSG(irc)

    -- This can happen in an abrubt teardown due to client rejecting
    -- this connection because of mismatched fingerprint or SASL
    -- failure, etc. Discard all remaining messages until next
    -- reconnect.
    if not irc_state then
        return
    end

    do
        local time_tag = irc.tags.time
        irc.time = time_tag and string.match(irc.tags.time, '^%d%d%d%d%-%d%d%-%d%dT(%d%d:%d%d:%d%d)%.%d%d%dZ$')
                or os.date '!%H:%M:%S'
    end
    irc.timestamp = uptime

    messages:insert(true, irc)
    irc_state.liveness = uptime

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

    for task, _ in pairs(irc_state.tasks) do
        if task.want_command[irc.command] then
            task:resume_irc(irc)
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
end

function conn_handlers.CON(fingerprint)
    status('irc', 'connected: %s', fingerprint)

    local want_fingerprint = configuration.fingerprint
    if mode_target ~= 'connected' then
        disconnect()
    elseif want_fingerprint and not string.match(fingerprint, want_fingerprint) then
        status('irc', 'bad fingerprint')
        disconnect()
    else
        Task('irc registration', irc_state.tasks, irc_registration)
    end
end

function conn_handlers.END(reason)
    disconnect()
    status('irc', 'disconnected: %s', reason or 'end of stream')

    -- do nothing on idle
    if mode_target == 'exit' then
        teardown()
    end
end

function conn_handlers.BAD(code)
    status('irc', 'message parse error: %d', code)
end

function disconnect()
    if irc_state then
        irc_state:close()
        irc_state = nil
        mode_current = 'idle'
        mode_timestamp = uptime
    end
end

-- starts the process of quitting the client
function quit()
    mode_target = 'exit'
    if mode_current == 'idle' then
        teardown()
    elseif mode_current == 'connected' then
        disconnect()
    end
end

function set_input_mode(mode, ...)
    -- remember the possible previous coroutine so we can abort it
    local task = password_task
    if task ~= nil then password_task = nil end

    input_mode = mode
    if mode == 'password' then
        password_label, password_task = ...
    end

    if task then
        task:resume()
    end
end

function set_talk_target(target)
    if target ~= talk_target then
        scroll = 0
        hscroll = 0
        talk_target_old = talk_target
        talk_target = target
    end
end

local function startup()
    -- initialize global variables
    if not messages then
        messages = OrderedMap(1000) -- Raw IRC protocol messages
        buffers = {} -- [irccase(target)] = {name=string, messages=OrderedMap, activity=number}
        status_messages = OrderedMap(100)
        channel_list = OrderedMap(10000)
        editor = Editor() -- contains history
        view = 'console'
        uptime = 0 -- seconds since startup
        scroll = 0
        hscroll = 0
        status_message = '' -- drawn on the bottom line
        mode_target = 'connected' -- exit, idle, connected
        mode_current = 'idle'
        mode_timestamp = 0 -- time that mode_current changed
        terminal_focus = true
        notification_muted = {}
        client_tasks = {} -- tasks not associated with any particular irc_state
        textbox_offset = 0
    end

    commands = require 'handlers.commands'

    -- Load configuration =============================================

    do
        local config_home = os.getenv 'XDG_CONFIG_HOME'
                        or path.join(assert(os.getenv 'HOME', 'HOME not set'), '.config')
        config_dir = path.join(config_home, 'snowcone')

        local flags = app.parse_args(arg, {config=true})
        if not flags then
            error("Failed to parse command line flags")
        end
        local settings_filename = flags.config or path.join(config_dir, 'settings.lua')
        local settings_file = file.read(settings_filename)
        if not settings_file then
            error("Failed to read settings file: " .. settings_filename, 0)
        end
        configuration = pretty.read(settings_file)
        if not configuration then
            error("Failed to parse settings file: " .. settings_filename, 0)
        end
    end

    -- Validate configuration =========================================

    local schema = require 'utils.schema'
    local configuration_schema = require 'utils.configuration_schema'
    schema.check(configuration_schema, configuration)

    -- Plugins ========================================================

    plugin_manager.startup()

    -- Timers =========================================================

    if not tick_timer then
        tick_timer = snowcone.newtimer()
        local function cb()
            tick_timer:start(1000, cb)
            uptime = uptime + 1

            if irc_state then
                if irc_state.phase == 'connected' and uptime == irc_state.liveness + 30 then
                    send('PING', os.time())
                elseif uptime == irc_state.liveness + 60 then
                    disconnect()
                end
            elseif mode_current == 'idle'
            and mode_target == 'connected'
            and uptime == mode_timestamp + 5 then
                connect()
            end
            draw()
        end
        tick_timer:start(1000, cb)
    end

    if mode_target == 'connected' and mode_current == 'idle' then
        connect()
    end
end

local success, error_message = pcall(startup)
if not success then
    status('startup', 'Error: %s', error_message)
    set_view 'status'
    draw()
end
