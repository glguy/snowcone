-- Library imports
Set    = require 'pl.Set'
tablex = require 'pl.tablex'

if not uptime then
    require 'pl.stringx'.import()
    require 'pl.app'.require_here()
end

addstr = ncurses.addstr
mvaddstr = ncurses.mvaddstr

function normal()       ncurses.attrset(ncurses.A_NORMAL)     end
function bold()         ncurses.attron(ncurses.A_BOLD)        end
function bold_()        ncurses.attroff(ncurses.A_BOLD)       end
function reversevideo() ncurses.attron(ncurses.A_REVERSE)     end
function reversevideo_()ncurses.attroff(ncurses.A_REVERSE)    end
function underline()    ncurses.attron(ncurses.A_UNDERLINE)   end
function underline_()   ncurses.attroff(ncurses.A_UNDERLINE)  end
function red()          ncurses.attron(ncurses.red)           end
function green()        ncurses.attron(ncurses.green)         end
function blue()         ncurses.attron(ncurses.blue)          end
function cyan()         ncurses.attron(ncurses.cyan)          end
function black()        ncurses.attron(ncurses.black)         end
function magenta()      ncurses.attron(ncurses.magenta)       end
function yellow()       ncurses.attron(ncurses.yellow)        end
function white()        ncurses.attron(ncurses.white)         end

local spinner = {'◴','◷','◶','◵'}

function require_(name)
    package.loaded[name] = nil
    return require(name)
end

-- Local modules ======================================================

servers  = require_ 'servers'
ip_org   = require_ 'ip_org'
irc_authentication = require_ 'irc_authentication'

local LoadTracker        = require_ 'LoadTracker'
local OrderedMap         = require_ 'OrderedMap'
local compute_kline_mask = require_ 'libera_masks'

-- Global state =======================================================

local views

local rotations = {
    ['irc.libera.chat'] = '',
    ['irc.ipv4.libera.chat'] = 'IPV4',
    ['irc.ipv6.libera.chat'] = 'IPV6',
    ['irc.eu.libera.chat'] = 'EU',
    ['irc.ea.libera.chat'] = 'EA',
    ['irc.us.libera.chat'] = 'US',
    ['irc.au.libera.chat'] = 'AU',
}

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
    users = OrderedMap(),
    exits = OrderedMap(),
    messages = OrderedMap(),
    kline_tracker = LoadTracker(),
    conn_tracker = LoadTracker(),
    exit_tracker = LoadTracker(),
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

    -- settings
    history = 1000,
    show_reasons = true,
    kline_duration = 1,
    kline_reason = 1,
    trust_uname = false,
    primary_hub = 'xenon.libera.chat',
    region_color = {
        US = red,
        EU = blue,
        AU = white,
        EA = green,
    },
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
for server, _ in pairs(servers) do
    conn_tracker:track(server, 0)
    exit_tracker:track(server, 0)
end

-- Kline logic ========================================================

kline_durations = {
    {'4h','240'},
    {'1d','1400'},
    {'3d','4320'}
}

kline_reasons = {
    {'plain',      'Please email bans@libera.chat to request assistance with this ban.'},
    {'dronebl',    'Please email bans@libera.chat to request assistance with this ban.|!dnsbl'},
    {'broken',     'Your client is repeatedly reconnecting. Please email bans@libera.chat when fixed.'},
}

function entry_to_kline(entry)
    local success, mask = pcall(compute_kline_mask, entry.user, entry.ip, entry.host, trust_uname)
    if success then
        staged_action = {action='kline', mask=mask, entry=entry}
        send_irc('TESTMASK ' .. mask .. '\r\n')
    else
        staged_action = nil
    end
end

function entry_to_unkline(entry)
    local mask = entry.user .. '@' .. entry.ip
    send_irc('TESTLINE ' .. mask .. '\r\n')
    staged_action = {action = 'unkline', entry = entry}
end

function kline_ready()
    return (view == 1 or view == 3)
       and staged_action ~= nil
       and staged_action.action == 'kline'
end

function unkline_ready()
    return (view == 1 or view == 3)
        and staged_action ~= nil
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

function add_button(text, action)
    local y1,x1 = ncurses.getyx()
    reversevideo()
    addstr(text)
    reversevideo_()
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
    mvaddstr(tty_height-1, 0, 'sn' .. spinner[uptime % #spinner + 1] .. 'wcone')
    reversevideo_()
    addstr(' ')
    magenta()
    addstr(title .. ' ')
    draw_load(tracker.global)
    normal()

    if view == 1 or view == 3 then
        if status_message then
            addstr(' ' .. status_message)
        end
    elseif view == 2 or view == 4 then
        local n = 0
        for _,v in pairs(population) do n = n + v end
        addstr('              ')
        magenta()
        add_population(n)
    end

    add_click(tty_height-1, 0, 9, function()
        view = view % #views + 1
    end)
end

function show_entry(entry)
    return
    (server_filter == nil or server_filter == entry.server) and
    (conn_filter == nil or conn_filter == entry.connected) and
    (filter      == nil or string.match(entry.mask, filter))
end

function draw_buttons()
    mvaddstr(tty_height-2, 0, ' ')
    bold()

    black()
    add_button('[ REASON ]', function()
        show_reasons = not show_reasons
    end)
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
        string.format('[ %-7s ]', kline_reasons[kline_reason][1])
    add_button(blacklist_text, function()
        kline_reason = kline_reason % #kline_reasons + 1
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
            send_irc(
                string.format('KLINE %s %s :%s\r\n',
                    kline_durations[kline_duration][2],
                    staged_action.mask,
                    kline_reasons[kline_reason][2]
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
                send_irc(
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

local view_server_load = require_ 'view_server_load'
local view_simple_load = require_ 'view_simple_load'
views = {
    -- Recent connections
    require_ 'view_recent_conn',
    -- Server connections
    view_server_load('Connection History', 'CLICON', ncurses.green, conn_tracker),
    -- Recent exists
    require_ 'view_recent_exit',
    -- Server exits
    view_server_load('Disconnection History', 'CLIEXI', ncurses.red, exit_tracker),
    -- K-Line tracking
    view_simple_load('K-Liner', 'KLINES', 'K-Line History', kline_tracker),
    -- Filter tracking
    view_simple_load('Server', 'FILTERS', 'Filter History', filter_tracker),
    -- Repeat connection tracking
    require_ 'view_reconnects',
    require_ 'view_client',
}

function draw()
    clicks = {}
    ncurses.erase()
    normal()
    views[view]:render()
    ncurses.refresh()
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

local irc_handlers = require_ 'handlers_irc'
function M.on_irc(irc)
    messages:insert(true, irc)
    while messages.n > 100 do
        messages:pop_back()
    end

    local f = irc_handlers[irc.command]
    if f then
        f(irc)
    end
end

function M.on_timer()
    if 0 == uptime % 30 then
        for k,_ in pairs(rotations) do
            dnslookup(k)
        end
    end

    uptime = uptime + 1
    conn_tracker:tick()
    exit_tracker:tick()
    kline_tracker:tick()
    filter_tracker:tick()
    draw()
end

local keys = {
    [ncurses.KEY_F1] = function() view = 1 scroll = 0 end,
    [ncurses.KEY_F2] = function() view = 2 end,
    [ncurses.KEY_F3] = function() view = 3 end,
    [ncurses.KEY_F4] = function() view = 4 end,
    [ncurses.KEY_F5] = function() view = 5 end,
    [ncurses.KEY_F6] = function() view = 6 end,
    [ncurses.KEY_F7] = function() view = 7 end,
    [ncurses.KEY_F8] = function() view = 8 end,
    --[[^L]] [ 12] = function() ncurses.clear() end,
}

function M.on_keyboard(key)
    local f = keys[key]
    if f then
        f()
        draw()
    else
        views[view]:keypress(key)
    end
end

function M.on_dns(name, addrs, reason)
    if addrs then
        mrs[rotations[name]] = Set(addrs)
    else
        status_message = name .. ' - ' .. reason
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

function M.on_connect(f)
    send_irc = f
    irc_state = { nick = configuration.irc_nick }
    status_message = 'connecting'

    local pass = ''
    if configuration.irc_pass then
        pass = 'PASS ' .. configuration.irc_pass .. '\r\n'
    end

    local user = configuration.irc_user or configuration.irc_nick
    local gecos = configuration.irc_gecos or configuration.irc_nick

    local first = 'MAP\r\nLINKS\r\n'
    if configuration.irc_oper_username and configuration.irc_challenge_key then
        first = 'CHALLENGE ' .. configuration.irc_oper_username .. '\r\n'
        irc_state.challenge = ''
    elseif configuration.irc_oper_username and configuration.irc_oper_password then
        first = 'OPER ' ..
            configuration.irc_oper_username .. ' ' ..
            configuration.irc_oper_password .. '\r\n'
    end

    local caps = {}
    if configuration.irc_capabilities then
        table.insert(caps, configuration.irc_capabilities)
    end

    local auth = ''
    if configuration.irc_sasl_mechanism == "EXTERNAL" then
        table.insert(caps, 'sasl')
        auth = irc_authentication.sasl('EXTERNAL', '')
    elseif configuration.irc_sasl_mechanism == "PLAIN" then
        table.insert(caps, 'sasl')
        auth = irc_authentication.sasl('PLAIN',
                '\0' .. configuration.irc_sasl_username ..
                '\0' .. configuration.irc_sasl_password)
    end

    local capreq = ''
    if next(caps) then
        capreq = 'CAP REQ :' .. table.concat(caps, ',') .. '\r\n'
    end

    send_irc(
        'CAP LS 302\r\n' ..
        pass ..
        'NICK ' .. configuration.irc_nick .. '\r\n' ..
        'USER ' .. user .. ' * * ' .. gecos .. '\r\n' ..
        capreq ..
        auth ..
        'CAP END\r\n' ..
        first)
end

function M.on_disconnect()
    send_irc = nil
    irc_state = nil
    status_message = 'disconnected'
end

return M
