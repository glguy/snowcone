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

local LoadTracker        = require_ 'LoadTracker'
local OrderedMap         = require_ 'OrderedMap'
local compute_kline_mask = require_ 'libera_masks'

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
    messages = OrderedMap(100),
    klines = OrderedMap(100),
    kline_tracker = LoadTracker(),
    conn_tracker = LoadTracker(),
    exit_tracker = LoadTracker(),
    net_trackers = {},
    view = 1,
    uptime = 0,
    mrs = {},
    scroll = 0,
    clicon_n = 0,
    cliexit_n = 0,
    filter_tracker = LoadTracker(),
    population = {},
    links = {},
    upstream = {},
    status_message = '',
    irc_state = {},
    uv_resources = {},

    -- settings
    show_reasons = 'reason',
    kline_duration = 1,
    kline_reason = 1,
    trust_uname = false,
    server_ordering = 'name',
    server_descending = false,
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
        staged_action = {action='kline', mask=mask, entry=entry}
        snowcone.send_irc('TESTMASK ' .. mask .. '\r\n')
    else
        staged_action = nil
    end
end

function entry_to_unkline(entry)
    local mask = entry.user .. '@' .. entry.ip
    snowcone.send_irc('TESTLINE ' .. mask .. '\r\n')
    staged_action = {action = 'unkline', entry = entry}
end

function kline_ready()
    return staged_action ~= nil
       and staged_action.action == 'kline'
end

function unkline_ready()
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
    mvaddstr(tty_height-1, 0, views[view].title or 'sn' .. spinner[uptime % #spinner + 1] .. 'wcone')
    reversevideo_()
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

    add_click(tty_height-1, 0, 9, function()
        view = view % #views + 1
    end)
end

function show_entry(entry)
    return
    (server_filter == nil or server_filter == entry.server) and
    (conn_filter == nil or conn_filter == not entry.reason) and
    (filter      == nil or string.match(entry.mask, filter))
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
            staged_action.entry.nick,
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
            staged_action.entry.nick,
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
    end

    normal()
end

local view_recent_conn = require_ 'view_recent_conn'
local view_server_load = require_ 'view_server_load'
local view_simple_load = require_ 'view_simple_load'
views = {
    -- Recent connections
    view_recent_conn(users, 'clicon_n', 'CLICON', conn_tracker),
    -- Server connections
    view_server_load('Connection History', 'CLICON', ncurses.green, conn_tracker),
    -- Recent exists
    view_recent_conn(exits, 'cliexit_n', 'CLIEXI', exit_tracker),
    -- Server exits
    view_server_load('Disconnection History', 'CLIEXI', ncurses.red, exit_tracker),
    -- K-Line tracking
    view_simple_load('banload ', 'K-Liner', 'KLINES', 'K-Line History', kline_tracker),
    -- Filter tracking
    view_simple_load('spamload', 'Server', 'FILTERS', 'Filter History', filter_tracker),
    -- Repeat connection tracking
    require_ 'view_reconnects',
    -- Raw IRC console
    require_ 'view_client',
    -- Counters for network masks
    require_ 'view_net_trackers',
    (require_ 'view_klines'),
}

function draw()
    clicks = {}
    ncurses.erase()
    normal()
    views[view]:render()
    ncurses.refresh()
end

-- Network Tracker Logic ==============================================

function add_network_tracker(name, mask)
    local address, prefix = string.match(mask, '^([^/]*)/(%d+)$')
    local b = snowcone.pton(address)
    if not net_trackers[name] then
        net_trackers[name] = NetTracker()
    end

    net_trackers[name]:track(mask, b, math.tointeger(prefix))
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
        pass = 'PASS ' .. configuration.irc_pass .. '\r\n'
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
        'USER ' .. user .. ' * * ' .. gecos .. '\r\n' ..
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

local keys = {
    --[[Esc]][0x1b] = function()
        reset_filter()
        status_message = nil
    end,
    [-ncurses.KEY_F1] = function() view = 1 scroll = 0 end,
    [-ncurses.KEY_F2] = function() view = 2 end,
    [-ncurses.KEY_F3] = function() view = 3 scroll = 0 end,
    [-ncurses.KEY_F4] = function() view = 4 end,
    [-ncurses.KEY_F5] = function() view = 5 end,
    [-ncurses.KEY_F6] = function() view = 6 end,
    [-ncurses.KEY_F7] = function() view = 7 end,
    [-ncurses.KEY_F8] = function() view = 8 end,
    [-ncurses.KEY_F9] = function() view = 9 end,
    [-ncurses.KEY_F10] = function() view = 10 end,

    --[[^L]] [ 12] = function() ncurses.clear() end,
    --[[^N]] [ 14] = function() view = view % #views + 1 end,
    --[[^P]] [ 16] = function() view = (view - 2) % #views + 1 end,
}

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

local irc_handlers = require_ 'handlers_irc'
function M.on_irc(irc)
    messages:insert(true, irc)

    local f = irc_handlers[irc.command]
    if f then
        f(irc)
    end
end

function M.on_keyboard(key)
    local f = keys[key]
    if f then
        f()
        draw()
    else
        views[view]:keypress(key)
    end
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
