-- Library imports
Set    = require 'pl.Set'
tablex = require 'pl.tablex'
pretty = require 'pl.pretty'
path   = require 'pl.path'
file   = require 'pl.file'

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

local spinner = {'◴','◷','◶','◵'}

function require_(name)
    package.loaded[name] = nil
    return require(name)
end

-- Local modules ======================================================

ip_org   = require_ 'ip_org'
irc_authentication = require_ 'irc_authentication'
NetTracker = require_ 'NetTracker'
local Editor             = require_ 'Editor'
local LoadTracker        = require_ 'LoadTracker'
local OrderedMap         = require_ 'OrderedMap'
local compute_kline_mask = require_ 'libera_masks'

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
    klines = OrderedMap(1000),
    kline_tracker = LoadTracker(),
    conn_tracker = LoadTracker(),
    exit_tracker = LoadTracker(),
    net_trackers = {},
    view = 1,
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

local repls = {
    ['\x00'] = '␀', ['\x01'] = '␁', ['\x02'] = '␂', ['\x03'] = '␃',
    ['\x04'] = '␄', ['\x05'] = '␅', ['\x06'] = '␆', ['\x07'] = '␇',
    ['\x08'] = '␈', ['\x09'] = '␉', ['\x0a'] = '␤', ['\x0b'] = '␋',
    ['\x0c'] = '␌', ['\x0d'] = '␍', ['\x0e'] = '␎', ['\x0f'] = '␏',
    ['\x10'] = '␐', ['\x11'] = '␑', ['\x12'] = '␒', ['\x13'] = '␓',
    ['\x14'] = '␔', ['\x15'] = '␕', ['\x16'] = '␖', ['\x17'] = '␗',
    ['\x18'] = '␘', ['\x19'] = '␙', ['\x1a'] = '␚', ['\x1b'] = '␛',
    ['\x1c'] = '␜', ['\x1d'] = '␝', ['\x1e'] = '␞', ['\x1f'] = '␟',
    ['\x7f'] = '␡',
}
function scrub(str)
    return string.gsub(str, '%c', repls)
end

-- Kline logic ========================================================

kline_durations = {
    {'4h','240'},
    {'1d','1400'},
    {'3d','4320'}
}

function entry_to_kline(entry)
    local success, mask = pcall(compute_kline_mask, entry.user, entry.ip, entry.host, trust_uname)
    if success then
        staged_action = {action = 'kline', mask = mask, nick = entry.nick, entry = entry}
        snowcone.send_irc('TESTMASK ' .. mask .. '\r\n')
    else
        staged_action = nil
    end
end

function entry_to_unkline(entry)
    local mask = entry.user .. '@' .. entry.ip
    snowcone.send_irc('TESTLINE ' .. mask .. '\r\n')
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

function add_population(pop)
    if pop then
        if pop < 1000 then
            addstr(string.format('  %5d', pop))
        else
            bold()
            addstr(string.format('  %2d', pop // 1000))
            bold_()
            addstr(string.format('%03d', pop % 1000))
        end
    else
        addstr('      ?')
    end
end

local function draw_load_1(avg, i)
    if avg.n >= 60*i then
        bold()
        addstr(string.format('%5.2f ', avg[i]))
        bold_()
    else
        addstr(string.format('%5.2f ', avg[i]))
    end
end

function draw_load(avg)
    draw_load_1(avg, 1)
    draw_load_1(avg, 5)
    draw_load_1(avg,15)
    addstr('[')
    underline()
    addstr(avg:graph())
    underline_()
    addstr(']')
end

function draw_global_load(title, tracker)
    if kline_ready() then red () else white() end
    reversevideo()
    if views[view].title then
        mvaddstr(tty_height-1, 0, string.format('%-8.8s', views[view].title))
    else
        mvaddstr(tty_height-1, 0, 'sn' .. spinner[uptime % #spinner + 1] .. 'wcone')
    end
    reversevideo_()

    if input_mode then
        ncurses.colorset(ncurses.white_blue)
        addstr('' .. input_mode)
        blue()
        addstr(' ')

        if input_mode == 'filter' and not pcall(string.match, '', editor.rendered) then
            red()
        end

        addstr(editor.before_cursor)
        local y,x = ncurses.getyx()
        addstr(editor.at_cursor)
        ncurses.move(y,x)
        ncurses.cursset(1)
    else
        addstr(' ')
        magenta()
        addstr(title .. ' ')
        draw_load(tracker.global)
        normal()

        if view == 2 or view == 4 then
            local n = 0
            for _,v in pairs(population) do n = n + v end
            addstr('              ')
            magenta()
            add_population(n)
            normal()
        end

        if status_message then
            addstr(' ' .. status_message)
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

        add_click(tty_height-1, 0, 9, function()
            view = view % #views + 1
        end)
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
        add_button('[  ORG   ]', function() show_reasons = 'ip' end)
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
    -- Recent connections
    view_recent_conn(users, 'CLICON', conn_tracker),
    -- Server connections
    view_server_load('Connection History', 'CLICON', ncurses.green, conn_tracker),
    -- Recent exists
    view_recent_conn(exits, 'CLIEXI', exit_tracker),
    -- Server exits
    view_server_load('Disconnection History', 'CLIEXI', ncurses.red, exit_tracker),
    -- K-Line tracking
    view_simple_load('banload', 'K-Liner', 'KLINES', 'K-Line History', kline_tracker),
    -- Filter tracking
    view_simple_load('spamload', 'Server', 'FILTERS', 'Filter History', filter_tracker),
    -- Repeat connection tracking
    require_ 'view.repeats',
    -- Raw IRC console
    require_ 'view.console',
    -- Counters for network masks
    require_ 'view.netcount',
    (require_ 'view.bans'),
}

-- hidden views not in main rotation
views.stats = require_ 'view.stats'

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

    local auth = ''
    if configuration.irc_sasl_mechanism == "EXTERNAL" then
        table.insert(caps, 'sasl')
        auth = irc_authentication.sasl('EXTERNAL', '')
        irc_state.sasl = true
    elseif configuration.irc_sasl_mechanism == "PLAIN" then
        table.insert(caps, 'sasl')
        auth = irc_authentication.sasl('PLAIN',
                '\0' .. configuration.irc_sasl_username ..
                '\0' .. configuration.irc_sasl_password)
        irc_state.sasl = true
    end

    local capreq = ''
    local capend = ''
    if next(caps) then
        capreq =
            'CAP REQ :' .. table.concat(caps, ' ') .. '\r\n'
        if irc_state.sasl then
            irc_state.in_cap = true
        else
            capend = 'CAP END\r\n'
        end
    end

    irc_state.registration = true
    snowcone.send_irc(
        capreq ..
        pass ..
        'NICK ' .. configuration.irc_nick .. '\r\n' ..
        'USER ' .. user .. ' * * :' .. gecos .. '\r\n' ..
        auth ..
        capend
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
                status_message = entry.hostname .. ' - ' .. reason
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
    messages:insert(true, irc)
    liveness = uptime
    local f = irc_handlers[irc.command]
    if f then
        f(irc)
    end
end

local key_handlers = require_ 'handlers.keyboard'
function M.on_keyboard(key)
    -- buffer text editing
    if input_mode and (0x20 <= key and (key < 0x7f or 0xa0 <= key)) then
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
            return
        end
    end
end

function M.on_connect()
    irc_state = { nick = configuration.irc_nick }
    status_message = 'connecting'
    irc_register()
end

function M.on_disconnect()
    irc_state = {}
    status_message = 'disconnected'
end

snowcone.setmodule(M)
