-- Library imports
local Set    = require 'pl.Set'
local tablex = require 'pl.tablex'
local pretty = require 'pl.pretty'
local path   = require 'pl.path'
local file   = require 'pl.file'

if not uptime then
    require 'pl.stringx'.import()
    require 'pl.app'.require_here()
end

addstr = ncurses.addstr
mvaddstr = ncurses.mvaddstr

function normal()       ncurses.attrset(ncurses.WA_NORMAL, 0)   end
function bold()         ncurses.attron(ncurses.WA_BOLD)         end
function bold_()        ncurses.attroff(ncurses.WA_BOLD)        end
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

local NetTracker         = require_ 'components.NetTracker'
local Editor             = require_ 'components.Editor'
local LoadTracker        = require_ 'components.LoadTracker'
local OrderedMap         = require_ 'components.OrderedMap'
local libera_masks       = require_ 'utils.libera_masks'
local sasl               = require_ 'sasl'
local addircstr          = require_ 'utils.irc_formatting'
local drawing            = require_ 'utils.drawing'

-- Validate configuration =============================================

if string.match(configuration.irc_nick, '[ \n\r]') then
    error 'Invalid character in nickname'
end

if configuration.irc_user and string.match(configuration.irc_user, '[ \n\r]') then
    error 'Invalid character in username'
end

if configuration.irc_gecos and string.match(configuration.irc_gecos, '[\n\r]') then
    error 'Invalid character in GECOS'
end

if configuration.irc_pass and string.match(configuration.irc_pass, '[\n\r]') then
    error 'Invalid character in server password'
end

if configuration.irc_oper_username and string.match(configuration.irc_oper_username, '[ \n\r]') then
    error 'Invalid character in operator username'
end

if configuration.irc_capabilities and string.match(configuration.irc_capabilities, '[\n\r]') then
    error 'Invalid character in capabilities'
end

-- Load network configuration =========================================

do
    servers = { servers = {}, regions = {},
        kline_reasons = { 'banned', "You are banned."} }
    local conf = configuration.network_filename
    if not conf then
        local xdgconf = os.getenv 'XDG_CONFIG_HOME'
        if not xdgconf then
            xdgconf = path.join(os.getenv 'HOME', '.config')
        end
        conf = path.join(xdgconf, "snowcone", "servers.lua")
    end
    local txt, file_err = file.read(conf)
    if txt then
        local val, lua_err = pretty.read(txt)
        if val then
            servers = val
        else
            error('Failed to parse ' .. conf .. '\n' .. lua_err)
        end
    elseif configuration.network_filename then
        error(file_err)
    end
end

-- Global state =======================================================

function reset_filter()
    filter = nil
    server_filter = nil
    conn_filter = nil
    highlight = nil
    highlight_plain = false
    staged_action = nil
end

local defaults = {
    -- state
    users = OrderedMap(1000),
    exits = OrderedMap(1000),
    messages = OrderedMap(1000),
    status_messages = OrderedMap(100),
    klines = OrderedMap(1000),
    new_channels = OrderedMap(100),
    kline_tracker = LoadTracker(),
    conn_tracker = LoadTracker(),
    exit_tracker = LoadTracker(),
    net_trackers = {},
    view = 'cliconn',
    uptime = 0, -- seconds since startup
    liveness = 0, -- timestamp of last irc receipt
    mrs = {},
    scroll = 0,
    filter_tracker = LoadTracker(),
    population = {},
    links = {},
    upstream = {},
    status_message = '',
    irc_state = {},
    uv_resources = {},
    editor = Editor(),
    versions = {},
    uptimes = {},

    -- settings
    show_reasons = 'reason',
    kline_duration = 1,
    kline_reason = 1,
    trust_uname = false,
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

kline_durations = {
    {'4h','240'},
    {'1d','1400'},
    {'3d','4320'}
}

function entry_to_kline(entry)
    local success, mask = pcall(libera_masks, entry.user, entry.ip, entry.host, trust_uname)
    if success then
        staged_action = {action = 'kline', mask = mask, nick = entry.nick, entry = entry}
        snowcone.send_irc('TESTMASK ' .. mask .. '\r\n')
    else
        staged_action = nil
    end
end

function entry_to_unkline(entry)
    local mask = entry.user .. '@' .. entry.ip
    snowcone.send_irc('TESTKLINE ' .. mask .. '\r\n')
    staged_action = {action = 'unkline', nick = entry.nick}
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
    local titlecolor = ncurses.white
    if kline_ready() then
        titlecolor = ncurses.red
    end

    ncurses.colorset(ncurses.black, titlecolor)
    mvaddstr(tty_height-1, 0, string.format('%-8.8s', view))

    if input_mode then
        ncurses.colorset(titlecolor, ncurses.blue)
        addstr('')
        ncurses.colorset(ncurses.white, ncurses.blue)
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

        if input_mode == 'filter' and not pcall(string.match, '', editor.rendered) then
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
    mvaddstr(tty_height-2, 0, ' ')
    bold()

    black()
    if show_reasons == 'reason' then

        add_button('[ REASON ]', function() show_reasons = 'org' end)
    elseif show_reasons == 'org' then
        add_button('[  ORG   ]', function() show_reasons = 'asn' end)
    elseif show_reasons == 'asn' then
        add_button('[  ASN   ]', function() show_reasons = 'ip' end)
    else
        add_button('[   IP   ]', function() show_reasons = 'reason' end)
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
    add_button('[ ' .. kline_durations[kline_duration][1] .. ' ]', function()
        kline_duration = kline_duration % #kline_durations + 1
    end)
    addstr ' '

    blue()
    add_button(trust_uname and '[ ~ ]' or '[ = ]', function()
        trust_uname = not trust_uname
        if staged_action and staged_action.action == 'kline' then
            entry_to_kline(staged_action.entry)
        end
    end)
    addstr ' '

    magenta()
    local blacklist_text =
        string.format('[ %-7s ]', servers.kline_reasons[kline_reason][1])
    add_button(blacklist_text, function()
        kline_reason = kline_reason % #servers.kline_reasons + 1
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
        local klineText = string.format('[ KLINE %s %s %s ]',
            staged_action.count and tostring(staged_action.count) or '?',
            staged_action.nick or '*',
            staged_action.mask)
        add_button(klineText, function()
            snowcone.send_irc(
                string.format('KLINE %s %s :%s\r\n',
                    kline_durations[kline_duration][2],
                    staged_action.mask,
                    servers.kline_reasons[kline_reason][2]
                )
            )
            staged_action = nil
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
                snowcone.send_irc(
                    string.format('UNKLINE %s\r\n',
                        staged_action.mask
                    )
                )
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
            snowcone.send_irc(
                string.format('UNDLINE %s\r\n', staged_action.mask)
            )
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
    connload = view_server_load('Connection History', 'cliconn', ncurses.green, conn_tracker),
    cliexit = view_recent_conn(exits, 'cliexit', exit_tracker),
    exitload = view_server_load('Disconnection History', 'cliexit', ncurses.red, exit_tracker),
    netcount = require_ 'view.netcount',
    bans = require_ 'view.bans',
    stats = require_ 'view.stats',
    repeats = require_ 'view.repeats',
    banload = view_simple_load('banload', 'K-Liner', 'KLINES', 'K-Line History', kline_tracker),
    spamload = view_simple_load('spamload', 'Server', 'FILTERS', 'Filter History', filter_tracker),
    console = require_ 'view.console',
    channels = require_ 'view.channels',
    status = require_ 'view.status',
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

function draw()
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
    if irc_state.oper then
        snowcone.send_irc('TESTMASK *@' .. mask .. '\r\n')
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
    local commands = {'MAP\r\nLINKS\r\n'}
    for _, entry in pairs(net_trackers) do
        for label, _ in pairs(entry.masks) do
            table.insert(commands, 'TESTMASK *@' .. label .. '\r\n')
        end
    end
    return table.concat(commands)
end

local function irc_register()
    local pass = ''
    if configuration.irc_pass then
        pass = 'PASS :' .. configuration.irc_pass .. '\r\n'
    end

    local user = configuration.irc_user or configuration.irc_nick
    local gecos = configuration.irc_gecos or configuration.irc_nick

    local caps = {}
    if configuration.irc_capabilities then
        table.insert(caps, configuration.irc_capabilities)
    end

    local postreg = ''
    local mech = configuration.irc_sasl_mechanism
    if mech then
        postreg, irc_state.sasl = sasl.start(
            configuration.irc_sasl_mechanism,
            configuration.irc_sasl_username,
            configuration.irc_sasl_password,
            configuration.irc_sasl_key,
            configuration.irc_sasl_authzid
        )
        table.insert(caps, 'sasl')
    end

    local capreq = ''
    if next(caps) then
        capreq = 'CAP REQ :' .. table.concat(caps, ' ') .. '\r\n'
        if not irc_state.sasl then
            postreg = 'CAP END\r\n'
        end
    end

    irc_state.registration = true
    snowcone.send_irc(
        capreq ..
        pass ..
        'NICK ' .. configuration.irc_nick .. '\r\n' ..
        'USER ' .. user .. ' * * :' .. gecos .. '\r\n' ..
        postreg
        )
end

-- Timers =============================================================

local function refresh_rotations()
    for label, entry in pairs(servers.regions or {}) do
        snowcone.dnslookup(entry.hostname, function(addrs, _, reason)
            if addrs then
                mrs[label] = Set(addrs)
            else
                mrs[label] = nil
                status('dns', '%s: %s', entry.hostname, reason)
            end
        end)
    end
end

if not uv_resources.rotations_timer then
    uv_resources.rotations_timer = snowcone.newtimer()
    uv_resources.rotations_timer:start(0, 30000, function()
        refresh_rotations()
    end)
end

if not uv_resources.tick_timer then
    uv_resources.tick_timer = snowcone.newtimer()
    uv_resources.tick_timer:start(1000, 1000, function()
        uptime = uptime + 1
        if uptime == liveness + 30 then
            snowcone.send_irc 'PING snowcone\r\n'
        end

        conn_tracker:tick()
        exit_tracker:tick()
        kline_tracker:tick()
        filter_tracker:tick()
        draw()
    end)
end

if not uv_resources.reloader then
    uv_resources.reloader = snowcone.newwatcher()
    uv_resources.reloader:start(path.dirname(configuration.lua_filename), function()
        assert(loadfile(configuration.lua_filename))()
    end)
end

function quit()
    snowcone.shutdown()
    for _, handle in pairs(uv_resources) do
        handle:close()
    end
    snowcone.send_irc 'QUIT\r\n'
    snowcone.send_irc(nil)
end

-- Callback Logic =====================================================

local M = {}

function M.on_input(str)
    local chunk, err = load(str, '=(load)', 't')
    if chunk then
        local returns = {chunk()}
        if #returns > 0 then
            print(table.unpack(returns))
        end
        draw()
    else
        print(err)
    end
end

local irc_handlers = require_ 'handlers.irc'
function M.on_irc(irc)
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
    liveness = uptime
    local f = irc_handlers[irc.command]
    if f then
        f(irc)
    end
end

function M.on_irc_err(msg)
    status('socat', '%s', msg)
end

local key_handlers = require_ 'handlers.keyboard'
function M.on_keyboard(key)
    -- buffer text editing
    if input_mode and 0x20 <= key and (key < 0x7f or 0xa0 <= key) then
        editor:add(key)
        draw()
        return
    end

    -- global key handlers
    local f = key_handlers[key]
    if f then
        f()
        draw()
        return
    end

    -- view-specific key handlers
    views[view]:keypress(key)
end

function M.on_mouse(y, x)
    for _, button in ipairs(clicks[y] or {}) do
        if button.lo <= x and x < button.hi then
            button.action()
            draw()
        end
    end
end

function M.on_connect()
    irc_state = { nick = configuration.irc_nick }
    status('irc', 'connecting')
    irc_register()
end

function M.on_disconnect()
    irc_state = {}
    status('irc', 'disconnected')
end

snowcone.setmodule(M)
