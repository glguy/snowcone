-- Library imports
local Set    = require 'pl.Set'
local tablex = require 'pl.tablex'
local pretty = require 'pl.pretty'
local path   = require 'pl.path'
local file   = require 'pl.file'
local app    = require 'pl.app'
local rex    = require 'rex_pcre2'

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
function red()          ncurses.colorset(ncurses.COLOR_RED)           end
function green()        ncurses.colorset(ncurses.COLOR_GREEN)         end
function blue()         ncurses.colorset(ncurses.COLOR_BLUE)          end
function cyan()         ncurses.colorset(ncurses.COLOR_CYAN)          end
function black()        ncurses.colorset(ncurses.COLOR_BLACK)         end
function magenta()      ncurses.colorset(ncurses.COLOR_MAGENTA)       end
function yellow()       ncurses.colorset(ncurses.COLOR_YELLOW)        end
function white()        ncurses.colorset(ncurses.COLOR_WHITE)         end

function require_(name)
    package.loaded[name] = nil
    return require(name)
end

-- Local modules ======================================================

local Irc                = require_ 'components.Irc'
local N                  = require 'utils.numerics'
local NetTracker         = require_ 'components.NetTracker'
local Task               = require_ 'components.Task'
local Editor             = require_ 'components.Editor'
local LoadTracker        = require_ 'components.LoadTracker'
local OrderedMap         = require_ 'components.OrderedMap'
local libera_masks       = require_ 'utils.libera_masks'
local addircstr          = require_ 'utils.irc_formatting'
local drawing            = require_ 'utils.drawing'
local utils_time         = require_ 'utils.time'
local send               = require_ 'utils.send'
local irc_registration   = require_ 'utils.irc_registration'
local plugin_manager     = require_ 'utils.plugin_manager'
local configuration_tools = require_ 'utils.configuration_tools'

-- Load configuration =================================================

do
    local config_home = os.getenv 'XDG_CONFIG_HOME'
                    or path.join(assert(os.getenv 'HOME', 'HOME not set'), '.config')
    config_dir = path.join(config_home, 'snowcone')

    local flags = app.parse_args(arg, {config=true})
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
end

if string.match(configuration.identity.nick, '[ \n\r]') then
    error 'Invalid character in nickname'
end

-- Validate configuration =============================================

if configuration.identity.user and string.match(configuration.identity.user, '[ \n\r]') then
    error 'Invalid character in username'
end

if configuration.identity.gecos and string.match(configuration.identity.gecos, '[\n\r]') then
    error 'Invalid character in GECOS'
end

if type(configuration.server.password) == 'string' and string.match(configuration.server.password, '[\n\r]') then
    error 'Invalid character in server password'
end

if configuration.oper and string.match(configuration.oper.username, '[ \n\r]') then
    error 'Invalid character in oper username'
end

if configuration.challenge and string.match(configuration.challenge.username, '[ \n\r]') then
    error 'Invalid character in challenge username'
end

-- Load network configuration =========================================

do
    servers = {
        servers = {},
        regions = {},
        kline_reasons = { 'banned', "You are banned."},
        kline_tags = {}
    }
    local conf = configuration.network and configuration.network.servers
    if not conf then
        conf = path.join(config_dir, "servers.lua")
    end
    local txt, file_err = file.read(conf)
    if txt then
        local val, lua_err = pretty.read(txt)
        if val then
            tablex.update(servers, val)
        else
            error('Failed to parse ' .. conf .. '\n' .. lua_err)
        end
    elseif configuration.network and configuration.network.servers then
        error(file_err)
    end
end

-- Global state =======================================================

function reset_filter()
    filter = nil
    server_filter = nil
    conn_filter = nil
    mark_filter = nil
    highlight = nil
    highlight_plain = false
    staged_action = nil
end

local defaults = {
    -- state
    users = OrderedMap(1000, snowcone.irccase),
    exits = OrderedMap(1000, snowcone.irccase),
    messages = OrderedMap(1000),
    status_messages = OrderedMap(100),
    klines = OrderedMap(1000),
    new_channels = OrderedMap(100, snowcone.irccase),
    kline_tracker = LoadTracker(),
    conn_tracker = LoadTracker(),
    exit_tracker = LoadTracker(),
    net_trackers = {},
    view = 'cliconn',
    uptime = 0, -- seconds since startup
    mrs = {},
    scroll = 0,
    filter_tracker = LoadTracker(),
    population = {},
    links = {},
    upstream = {},
    status_message = '',
    editor = Editor(),
    versions = {},
    uptimes = {},
    drains = {},
    sheds = {},
    client_tasks = {},

    -- settings
    show_reasons = 'reason',
    kline_duration = '1d',
    kline_reason = 1,
    kline_tag = 0,
    trust_uname = false,
    add_freeze = false,
    server_ordering = 'name',
    server_descending = false,
    watches = {},
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

-- Prepopulate the server list
for server, _ in pairs(servers.servers or {}) do
    conn_tracker:track(server, 0)
    exit_tracker:track(server, 0)
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

-- Kline logic ========================================================

kline_durations = {'4h','1d','3d'}

function entry_to_kline(entry)
    prepare_kline(entry.nick, entry.user, entry.host, entry.ip)
end

function prepare_kline(nick, user, host, ip)
    local success, mask = pcall(libera_masks, user, ip, host, trust_uname)
    if success then
        staged_action = {
            action = 'kline',
            mask = mask,
            nick = nick,
            user = user,
            host = host,
            ip = ip,
        }
        send('TESTMASK', mask)
    else
        status('kline', '%s', mask)
        staged_action = nil
    end
end

function entry_to_unkline(entry)
    local mask = entry.user .. '@' .. entry.ip
    staged_action = {action = 'unkline', nick = entry.nick}

    Task(irc_state.tasks, function(task)
        local replies = Set{N.RPL_NOTESTLINE, N.RPL_TESTLINE}
        send('TESTKLINE', mask)
        while true do
            local irc = task:wait_irc(replies)
            local command = irc.command

            if command == N.RPL_NOTESTLINE
            and irc[2] == mask
            then
                staged_action = nil
                return
            elseif command == N.RPL_TESTLINE
            and irc[2] == 'k'
            then
                staged_action.mask = irc[4]
                return
            end
        end
    end)
end

local function kline_ready()
    return staged_action ~= nil
       and staged_action.action == 'kline'
end

local function undline_ready()
    return staged_action ~= nil
       and staged_action.action == 'undline'
       and staged_action.mask ~= nil
end

local function unkline_ready()
    return staged_action ~= nil
       and staged_action.action == 'unkline'
       and staged_action.mask ~= nil
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

function draw_global_load(title, tracker)
    local titlecolor = ncurses.COLOR_WHITE
    if kline_ready() then
        titlecolor = ncurses.COLOR_RED
    end

    ncurses.colorset(ncurses.COLOR_BLACK, titlecolor)
    mvaddstr(tty_height-1, 0, string.format('%-8.8s', view))

    if input_mode then
        ncurses.colorset(titlecolor, ncurses.COLOR_BLUE)
        addstr('')
        ncurses.colorset(ncurses.COLOR_WHITE, ncurses.COLOR_BLUE)
        addstr(input_mode)
        blue()
        addstr('')

        if 1 < editor.first then
            yellow()
            addstr('…')
            blue()
        else
            addstr(' ')
        end

        if input_mode == 'filter' and not pcall(rex.new, editor:content()) then
            red()
        end

        local y0, x0 = ncurses.getyx()

        addstr(editor.before_cursor)

        -- cursor overflow: clear and redraw
        local y1, x1 = ncurses.getyx()
        if x1 == tty_width - 1 then
            yellow()
            mvaddstr(y0, x0-1, '…' .. string.rep(' ', tty_width)) -- erase line
            blue()
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
        magenta()
        addstr(title .. '')
        drawing.draw_load(tracker.global)
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

function draw_buttons()
    ncurses.move(tty_height-2, 0)
    bold()

    yellow()
    if show_reasons == 'reason' then
        add_button('[ REASON ]',
            function(shifted) show_reasons = shifted and 'ip' or 'org' end)
    elseif show_reasons == 'org' then
        add_button('[  ORG   ]',
            function(shifted) show_reasons = shifted and 'reason' or 'asn' end)
    elseif show_reasons == 'asn' then
        add_button('[  ASN   ]',
            function(shifted) show_reasons = shifted and 'org' or 'ip' end)
    else
        add_button('[   IP   ]',
            function(shifted) show_reasons = shifted and 'asn' or 'reason' end)
    end
    addstr ' '

    if filter then
        blue()
        add_button('[ CLEAR FILTER ]', function()
            filter = nil
        end)
        addstr ' '
    end

    cyan()
    add_button('[ ' .. kline_duration .. ' ]', function(shifted)
        local i = tablex.find(kline_durations, kline_duration) or 0
        local delta = shifted and -2 or 0
        kline_duration = kline_durations[(i + delta) % #kline_durations + 1]
    end)
    addstr ' '

    blue()
    add_button(trust_uname and '[ ~ ]' or '[ = ]', function()
        trust_uname = not trust_uname
        if staged_action and staged_action.action == 'kline' then
            prepare_kline(staged_action.nick, staged_action.user, staged_action.host, staged_action.ip)
        end
    end)
    addstr ' '

    local tag = servers.kline_tags[kline_tag]

    if add_freeze then
        if tag then
            red()
        else
            yellow()
        end
    end
    add_button(add_freeze and '[FR]' or '[  ]', function()
        add_freeze = not add_freeze
    end)
    addstr ' '

    magenta()
    local klinereason_text =
        string.format('[ %-7s ]', servers.kline_reasons[kline_reason][1])
    add_button(klinereason_text, function(shifted)
        local delta = shifted and -2 or 0
        kline_reason = (kline_reason + delta) % #servers.kline_reasons + 1
    end)
    addstr ' '

    magenta()
    local klinetag_text =
        string.format('[ %-7s ]', tag or 'no tag')
    add_button(klinetag_text, function(shifted)
        -- increment by one, but use 0 as disabled
        local delta = shifted and -1 or 1
        kline_tag = (kline_tag + delta) % (#servers.kline_tags + 1)
    end)
    addstr ' '

    if kline_ready() then
        green()
        add_button('[ CANCEL KLINE ]', function()
            staged_action = nil
            highlight = nil
            highlight_plain = nil
        end)

        addstr(' ')
        red()

        local freeze_account
        if tag and add_freeze and staged_action.nick then
            local user = users:lookup(staged_action.nick)
            if user then
                freeze_account = user.account
            end
        end

        local klineText
        if freeze_account then
            klineText = string.format('[ KLINE %s %s %s FREEZE %s ]',
                staged_action.count and tostring(staged_action.count) or '?',
                staged_action.nick or '*',
                staged_action.mask,
                freeze_account)
        else
            klineText = string.format('[ KLINE %s %s %s ]',
                staged_action.count and tostring(staged_action.count) or '?',
                staged_action.nick or '*',
                staged_action.mask)
        end
        add_button(klineText, function()
            local reason = servers.kline_reasons[kline_reason][2]

            if tag then
                if reason:find '|' then
                    reason = reason .. ' %' .. tag
                else
                    reason = reason .. '|%' .. tag
                end
            end

            send('KLINE',
                utils_time.parse_duration(kline_duration),
                staged_action.mask,
                reason
            )
            if freeze_account then
                send('NS', 'FREEZE', freeze_account, 'ON', '%' .. tag)
            end
            staged_action = nil
        end)

        addstr(' ')
        yellow()
        add_button('[ TRACE ]', function()
            send('MASKTRACE', staged_action.mask)
            view = 'console'
        end)

    elseif unkline_ready() then
        green()
        add_button('[ CANCEL UNKLINE ]', function()
            staged_action = nil
            highlight = nil
            highlight_plain = nil
        end)

        addstr(' ')
        yellow()
        local klineText = string.format('[ UNKLINE %s %s ]',
            staged_action.nick or '*',
            staged_action.mask or '?')
        add_button(klineText, function()
            if staged_action.mask then
                send('UNKLINE', staged_action.mask)
            end
            staged_action = nil
        end)
    elseif undline_ready() then
        green()
        add_button('[ CANCEL UNDLINE ]', function()
            staged_action = nil
        end)

        addstr(' ')
        yellow()
        local dlineText = string.format('[ UNDLINE %s ]', staged_action.mask)
        add_button(dlineText, function()
            send('UNDLINE', staged_action.mask)
            staged_action = nil
        end)
    end

    normal()
end

local view_recent_conn = require_ 'view.recent_conn'
local view_server_load = require_ 'view.server_load'
local view_simple_load = require_ 'view.simple_load'
views = {
    cliconn = view_recent_conn(users, 'cliconn', conn_tracker),
    connload = view_server_load('Connection History', 'cliconn', ncurses.COLOR_GREEN, conn_tracker),
    cliexit = view_recent_conn(exits, 'cliexit', exit_tracker),
    exitload = view_server_load('Disconnection History', 'cliexit', ncurses.COLOR_RED, exit_tracker),
    netcount = require_ 'view.netcount',
    bans = require_ 'view.bans',
    stats = require_ 'view.stats',
    repeats = require_ 'view.repeats',
    banload = view_simple_load('banload', 'K-Liner', 'KLINES', 'K-Line History', kline_tracker),
    spamload = view_simple_load('spamload', 'Server', 'FILTERS', 'Filter History', filter_tracker),
    console = require_ 'view.console',
    channels = require_ 'view.channels',
    status = require_ 'view.status',
    plugins = require_ 'view.plugins',
    help = require_ 'view.help',
}

main_views = {'cliconn', 'connload', 'cliexit', 'exitload', 'bans', 'channels', 'netcount', 'console'}

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

function draw()
    if 0 < drawing_suspended then return end
    clicks = {}
    ncurses.erase()
    normal()
    views[view]:render()
    ncurses.refresh()
end

-- Network Tracker Logic ==============================================

function add_network_tracker(name, mask)
    local address, prefix, b

    address, prefix = string.match(mask, '^([^/]*)/(%d+)$')
    if address then
        b = assert(snowcone.pton(address))
        prefix = math.tointeger(prefix)
    else
        b = assert(snowcone.pton(mask))
        prefix = 8 * #b
    end

    if not net_trackers[name] then
        net_trackers[name] = NetTracker()
    end

    net_trackers[name]:track(mask, b, prefix)
    if irc_state and irc_state.oper then
        send('TESTMASK', '*@' .. mask)
    end
end

for name, masks in pairs(servers.net_tracks or {}) do
    if not net_trackers[name] then
        for _, mask in ipairs(masks) do
            add_network_tracker(name, mask)
        end
    end
end

-- IRC Registration Logic =============================================

function counter_sync_commands()
    send('MAP')
    send('LINKS')
    for _, entry in pairs(net_trackers) do
        for label, _ in pairs(entry.masks) do
            send('TESTMASK', '*@' .. label)
        end
    end
end

-- Timers =============================================================

local function refresh_rotations()
    for label, entry in pairs(servers.regions or {}) do
        -- luacheck: ignore 231
        local query
        query = snowcone.dnslookup(entry.hostname, function(reason, ...)
            query = nil -- keeps the resolver alive until the callback is used
            mrs[label] = Set{...}
            if reason then
                status('dns', '%s: %s', entry.hostname, reason)
            end
        end)
    end
end

if not rotations_timer then
    rotations_timer = snowcone.newtimer()
    local function cb()
        rotations_timer:start(30000, cb)
        refresh_rotations()
    end
    cb()
end

if not tick_timer then
    tick_timer = snowcone.newtimer()
    local function cb()
        tick_timer:start(1000, cb)
        uptime = uptime + 1

        if irc_state then
            if irc_state.phase == 'connected' and uptime == irc_state.liveness + 30 then
                send('PING', 'snowcone')
            elseif uptime == irc_state.liveness + 60 then
                conn:close()
            end
        end

        conn_tracker:tick()
        exit_tracker:tick()
        kline_tracker:tick()
        filter_tracker:tick()
        draw()
        collectgarbage 'step'
    end
    tick_timer:start(1000, cb)
end

function quit(msg)
    if rotations_timer then
        rotations_timer:cancel()
        rotations_timer = nil
    end
    if tick_timer then
        tick_timer:cancel()
        tick_timer = nil
    end
    if reconnect_timer then
        reconnect_timer:cancel()
        reconnect_timer = nil
    end
    if conn then
        exiting = true
        disconnect(msg)
    else
        if not exiting then
            exiting = true
            snowcone.shutdown()
        end
    end
end

-- Load plugins

plugin_manager.startup()


-- Command handlers ===================================================

commands = require_ 'handlers.commands'

-- Callback Logic =====================================================

local connect

local irc_event = {}

function irc_event.CON()
    irc_state = Irc()
    status('irc', 'connected')
    if exiting then
        disconnect()
    else
        Task(irc_state.tasks, irc_registration)
    end
end

function irc_event.END(txt)
    irc_state = nil
    conn = nil
    status('irc', 'disconnected %s', txt)

    if exiting then
        snowcone.shutdown()
    else
        reconnect_timer = snowcone.newtimer()
        reconnect_timer:start(1000, function()
            reconnect_timer = nil
            connect()
        end)
    end
end

local irc_handlers = require_ 'handlers.irc'
function irc_event.MSG(irc)
    local time
    if irc.tags.time then
        time = string.match(irc.tags.time, '^%d%d%d%d%-%d%d%-%d%dT(%d%d:%d%d:%d%d)%.%d%d%dZ$')
    end
    if time == nil then
        time = os.date '!%H:%M:%S'
    end
    irc.time = time
    irc.timestamp = uptime

    messages:insert(true, irc)
    irc_state.liveness = uptime

    local f = irc_handlers[irc.command]
    if f then
        local success, message = pcall(f, irc)
        if not success then
            status('irc', 'irc handler error: %s', message)
        end
    end

    for task, _ in pairs(irc_state.tasks) do
        if task.want_command and task.want_command[irc.command] then
            task:resume_irc(irc)
        end
    end

    for _, plugin in pairs(plugins) do
        local h = plugin.irc
        if h then
            local success, err = pcall(h, irc)
            if not success then
                status(plugin.name, 'irc handler error: ' .. tostring(err))
            end
        end
    end
end

local function on_irc(event, irc)
    irc_event[event](irc)
end


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
    draw()
end

snowcone.setmodule(function(ev, ...)
    M[ev](...)
end)

function disconnect(msg)
    if conn then
        send('QUIT', msg or 'closing')
        conn = nil
    end
end

-- declared above so that it's in scope in on_irc
function connect()
    Task(client_tasks, function(task) -- passwords might need to suspend connecting

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
            status('connect', 'TLS client key password program error: %s', tls_client_password)
            return
        end

        ok, socks_password = pcall(configuration_tools.resolve_password, task, socks_password)
        if not ok then
            status('connect', 'SOCKS5 password program error: %s', socks_password)
            return
        end

        ok, tls_client_cert =
            pcall(configuration_tools.resolve_password, task, tls_client_cert)
        if not ok then
            status('connect', 'TLS client cert error: %s', tls_client_cert)
            return
        end

        ok, tls_client_key =
            pcall(configuration_tools.resolve_password, task, tls_client_key)
        if not ok then
            status('connect', 'TLS client key error: %s', tls_client_key)
            return
        end

        if not tls_client_key then tls_client_key = tls_client_cert end

        if tls_client_cert then
            ok, tls_client_cert = pcall(myopenssl.read_x509, tls_client_cert)
            if not ok then
                status('connect', 'Parse client cert failed: %s', tls_client_cert)
                return
            end
        end

        if tls_client_key then
            ok, tls_client_key = pcall(myopenssl.read_pem, tls_client_key, true, tls_client_password)
            if not ok then
                status('connect', 'Parse client key failed: %s', tls_client_key)
                return
            end
        end

        local conn_, errmsg =
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
            on_irc)

        if conn_ then
            conn = conn_
            status('irc', 'connecting')
        else
            status('irc', 'failed to connect: %s', errmsg)
        end

    end)
end

if not conn and configuration.server.host then
    connect()
end
