-- Library imports
Set    = require 'pl.Set'
tablex = require 'pl.tablex'

require 'pl.stringx'.import()
require 'pl.app'.require_here()

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

server_classes = require_ 'server_classes'
elements       = require_ 'elements'
ip_org         = require_ 'ip_org'

local LoadTracker        = require_ 'LoadTracker'
local OrderedMap         = require_ 'OrderedMap'
local compute_kline_mask = require_ 'libera_masks'
local views

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
    users = OrderedMap(),
    exits = OrderedMap(),
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
    clicks = {},
    population = {},
    links = {},
    upstream = {},

    -- settings
    history = 1000,
    show_reasons = true,
    kline_duration = 1,
    kline_reason = 1,
    trust_uname = false,
    primary_hub = 'helium.libera.chat',
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
for k,_ in pairs(server_classes) do
    local server = k..'.libera.chat'
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
        last_key = mask
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
    local y2,x2 = ncurses.getyx()
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

    if view == 2 or view == 4 then
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
}

function draw()
    clicks = {}
    ncurses.erase()
    normal()
    views[view]()
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
    local f = irc_handlers[irc.command]
    if f then
        f(irc)
    end
end

function M.on_timer()
    uptime = uptime + 1
    conn_tracker:tick()
    exit_tracker:tick()
    kline_tracker:tick()
    filter_tracker:tick()
    draw()
end

local keys = {
    [ncurses.KEY_F1] = function() view = 1 scroll = 0 draw() end,
    [ncurses.KEY_F2] = function() view = 2 draw() end,
    [ncurses.KEY_F3] = function() view = 3 draw() end,
    [ncurses.KEY_F4] = function() view = 4 draw() end,
    [ncurses.KEY_F5] = function() view = 5 draw() end,
    [ncurses.KEY_F6] = function() view = 6 draw() end,
    [ncurses.KEY_F7] = function() view = 7 draw() end,
    [ncurses.KEY_PPAGE] = function()
        scroll = scroll + math.max(1, tty_height - 1)
        scroll = math.min(scroll, users.n - 1)
        scroll = math.max(scroll, 0)
        draw()
    end,
    [ncurses.KEY_NPAGE] = function()
        scroll = scroll - math.max(1, tty_height - 1)
        scroll = math.max(scroll, 0)
        draw()
    end,
    --[[^L]] [ 12] = function() ncurses.clear() end,
    --[[ESC]][ 27] = function() reset_filter() end,
    --[[Q ]] [113] = function() conn_filter = true  end,
    --[[W ]] [119] = function() conn_filter = false end,
    --[[E ]] [101] = function() conn_filter = nil   end,
    --[[K ]] [107] = function()
        if staged_action.action == 'kline' then
            send_irc(
                string.format('KLINE %s %s :%s\r\n',
                    kline_durations[kline_duration][2],
                    staged_action.mask,
                    kline_reasons[kline_reason][2]
                )
            )
            staged_action = nil
        end
    end,
}

function M.on_keyboard(key)
    local f = keys[key]
    if f then
        last_key = nil
        f()
        draw()
    else
        last_key = key
    end
end

function M.on_mrs(x)
    mrs[x.name] = Set(x)
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
    send_irc 'MAP\r\nLINKS\r\n'
end

function M.on_disconnect()
    send_irc = nil
end

return M
