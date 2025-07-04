-- Library imports
local tablex = require 'pl.tablex'
local path   = require 'pl.path'
local file   = require 'pl.file'
local app    = require 'pl.app'
local lexer  = require 'pl.lexer'

if not uptime then
    warn '@on'
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
local send                <const> = require 'utils.send'
local Task                <const> = require 'components.Task'
local configuration_tools <const> = require 'utils.configuration_tools'
local NotificationManager <const> = require 'components.NotificationManager'
local PluginManager       <const> = require 'components.PluginManager'

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

    if textbox_pad then
        textbox_pad:delwin()
    end
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

-- Number of outstanding tty suspends
local drawing_suspended = 0

function suspend_tty()
    if drawing_suspended == 0 then
        snowcone.stop_input()
    end
    drawing_suspended = drawing_suspended + 1
end

function resume_tty()
    drawing_suspended = drawing_suspended - 1
    if drawing_suspended == 0 then
        snowcone.start_input()
    end
end

local function draw()
    if 0 < drawing_suspended then return end;

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
    for object, finalizer in pairs(background_resources) do
        object[finalizer](object)
        background_resources[finalizer] = nil
    end

    snowcone.shutdown()
end

local conn_handlers = {}

function connect()
    if mode_current == 'idle' then
        if configuration.server.host then
            mode_current = 'connecting'
            mode_timestamp = uptime
        else
            status('connect', 'Connect host not specified')
            return
        end
    elseif mode_current == 'connecting' then
        error 'already connecting'
    elseif mode_current == 'connected' then
        error 'already connected'
    else
        error 'PANIC: bad mode_current'
    end

    Task('connect', client_tasks, function(task) -- passwords might need to suspend connecting

        local function failure(...)
            status('connect', ...)
            mode_current = 'idle' -- exits connecting mode
            mode_timestamp = uptime
            if mode_target == 'connected' then mode_target = 'idle' end -- don't reconnect
        end

        local use_tls = nil ~= configuration.tls
        local use_socks = nil ~= configuration.socks

        local ok, tls_client_password, socks_password, tls_client_cert, tls_client_key

        if use_tls then
            tls_client_password = configuration.tls.client_password
            tls_client_key = configuration.tls.client_key
            tls_client_cert = configuration.tls.client_cert
        end

        if use_socks then
            socks_password = configuration.socks.password
        end

        ok, tls_client_password =
            pcall(configuration_tools.resolve_password, task, tls_client_password)
        if not ok then
            failure('TLS client key password program error: %s', tls_client_password)
            return
        end

        ok, socks_password = pcall(configuration_tools.resolve_password, task, socks_password)
        if not ok then
            failure('SOCKS5 password program error: %s', socks_password)
            return
        end

        ok, tls_client_cert =
            pcall(configuration_tools.resolve_password, task, tls_client_cert)
        if not ok then
            failure('TLS client cert error: %s', tls_client_cert)
            return
        end

        ok, tls_client_key =
            pcall(configuration_tools.resolve_password, task, tls_client_key)
        if not ok then
            failure('TLS client key error: %s', tls_client_key)
            return
        end

        if not tls_client_key then tls_client_key = tls_client_cert end

        if tls_client_cert then
            ok, tls_client_cert = pcall(myopenssl.read_x509, tls_client_cert)
            if not ok then
                failure('Parse client cert failed: %s', tls_client_cert)
                return
            end
        end

        if tls_client_key then
            if configuration.tls.use_store then
                ok, tls_client_key = pcall(myopenssl.pkey_from_store, tls_client_key, true, tls_client_password)
                if not ok then
                    failure('Client key from store failed: %s', tls_client_key)
                    return
                end
            else
                ok, tls_client_key = pcall(myopenssl.read_pem, tls_client_key, true, tls_client_password)
                if not ok then
                    failure('Parse client key failed: %s', tls_client_key)
                    return
                end
            end
        end

        local conn, errmsg =
            snowcone.connect(
            use_tls,
            configuration.server.host,
            configuration.server.port or use_tls and 6697 or 6667,
            tls_client_cert,
            tls_client_key,
            use_tls and configuration.tls.verify_host or nil,
            use_tls and configuration.tls.sni_host or nil,
            use_socks and configuration.socks.host or nil,
            use_socks and configuration.socks.port or nil,
            use_socks and configuration.socks.username or nil,
            socks_password,
            function(event, ...)
                conn_handlers[event](...)
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

function conn_handlers.MSG(irc, flush)

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

    do
        local source <const> = irc.source
        if source then
            irc.nick, irc.user, irc.host = source:match '^([^!]*)!([^@]*)@(.*)$'
        end
    end

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

    plugin_manager:dispatch_irc(irc)

    if flush then
        draw()
    end
end

function conn_handlers.CON(fingerprint)
    status('irc', 'connected: %s', fingerprint)

    local want_fingerprint = configuration.server.fingerprint
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

-- Parse a table assignment of the form: (key '.')* key '=' value
-- Key and value can be numbers, quoted strings, or unquoted strings
local function apply_override(tab, src)
    local keys = {}
    local key
    local value
    local want = 'key'
    for token, lexeme in lexer.scan(src) do
        if 'key' == want and ('iden' == token or 'string' == token or 'number' == token) then
            key = lexeme
            want = 'separator'
        elseif 'separator' == want and '.' == token then
            table.insert(keys, key)
            want = 'key'
        elseif 'separator' == want and '=' == token then
            want = 'value'
        elseif 'value' == want and ('iden' == token or 'string' == token or 'number' == token) then
            value = lexeme
            want = 'eol'
        else
            error(
                'syntax error at \x1f' .. lexeme ..
                '\x1f got \x02' .. token ..
                '\x02 expected \x02' .. want ..
                '\x02 in \x1f' .. src, 0)
        end
    end

    -- Parse succeeded; apply change
    for _, x in ipairs(keys) do
        if not tab[x] then
            tab[x] = {}
        end
        tab = tab[x]
    end
    tab[key] = value
end

local function startup()
    local initial = not messages
    -- initialize global variables
    if initial then
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
        client_tasks = {} -- tasks not associated with any particular irc_state
        textbox_offset = 0
        notification_manager = NotificationManager()
        plugin_manager = PluginManager()

        -- anything left behind in background_resources will be closed on teardown
        background_resources = {}
        setmetatable(background_resources, { __mode = "k" })

        local tick_timer = snowcone.newtimer()
        background_resources[tick_timer] = 'cancel'
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
            collectgarbage 'step'
        end
        tick_timer:start(1000, cb)
    end

    commands = require 'handlers.commands'

    -- Load configuration =============================================

    do
        local config_home = os.getenv 'XDG_CONFIG_HOME'
                        or path.join(assert(os.getenv 'HOME', 'HOME not set'), '.config')
        config_dir = path.join(config_home, 'snowcone')

        local flags, overrides = app.parse_args(arg, {config=true})
        if not flags then
            error("Failed to parse command line flags")
        end
        local settings_filename = nil
        local settings_file = nil
        if flags.config then
            settings_filename = flags.config
            settings_file = file.read(settings_filename)
            if not settings_file then
                error("Failed to read settings file: " .. settings_filename, 0)
            end
        else
            local default_settings = {path.join(config_dir, 'settings.lua'), path.join(config_dir, 'settings.toml')}
            for _, fn in ipairs(default_settings) do
                settings_filename = fn
                settings_file = file.read(settings_filename)
                if settings_file then
                    break
                end
            end
            if not settings_file then
                error("Failed to read settings file, tried: " .. table.concat(default_settings, ', '), 0)
            end
        end

        local ext = path.extension(settings_filename)
        if ext == '.toml' then
            configuration = assert(mytoml.parse_toml(settings_file))
        elseif ext == '.lua' then
            local chunk = assert(load(settings_file, settings_filename, 't'))
            configuration = chunk()
        else
            error ('Unknown configuration file extension: ' .. ext)
        end

        for _, override in ipairs(overrides) do
            apply_override(configuration, override)
        end
    end

    -- Validate configuration =========================================

    local schema = require 'utils.schema'
    local configuration_schema = require 'utils.configuration_schema'
    schema.check(configuration_schema, configuration)

    -- Plugins ========================================================

    notification_manager:load(
        configuration.notifications and configuration.notifications.module)

    plugin_manager:load(
            configuration_tools.resolve_path(configuration.plugins and configuration.plugins.directory) or
            path.join(config_dir, 'plugins'),
            configuration.plugins and configuration.plugins.modules or {}
    )

    -- Timers =========================================================

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
