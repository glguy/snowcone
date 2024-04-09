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
    local red_ = ncurses.red
    local green_ = ncurses.green
    local blue_ = ncurses.blue
    local cyan_ = ncurses.cyan
    local black_ = ncurses.black
    local magenta_ = ncurses.magenta
    local yellow_ = ncurses.yellow
    local white_ = ncurses.white

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

function require_(name)
    package.loaded[name] = nil
    return require(name)
end

-- Local modules ======================================================

local drawing            = require_ 'utils.drawing'
local Editor             = require_ 'components.Editor'
local Irc                = require_ 'components.Irc'
local irc_registration   = require_ 'utils.irc_registration'
local OrderedMap         = require_ 'components.OrderedMap'
local plugin_manager     = require_ 'utils.plugin_manager'
local send               = require_ 'utils.send'
local Task               = require_ 'components.Task'
local defaults = {
    -- state
    messages = OrderedMap(1000), -- Raw IRC protocol messages
    buffers = {}, -- [irccase(target)] = {name=string, messages=OrderedMap, seen=number}
    status_messages = OrderedMap(100),
    channel_list = OrderedMap(10000),
    editor = Editor(),
    view = 'console',
    uptime = 0, -- seconds since startup
    scroll = 0,
    hscroll = 0,
    status_message = '',
    objective = 'connect', -- exit, idle
    terminal_focus = true,
    notification_muted = {},

    tasks = {},
}

function initialize()
    tablex.update(_G, defaults)
    reset_filter()
end

function reset_filter()
    filter = nil
end

-- Make windows ==================================================

local thepad
local inputwin
local function make_layout()
    if thepad then
        thepad:delwin()
    end
    thepad = ncurses.newpad(tty_height-1, 550);
    if inputwin then
        inputwin:delwin()
    end
    inputwin = ncurses.newwin(1, tty_width, tty_height - 1, 0);
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
    stats = require_ 'view.stats',
    console = require_ 'view.console',
    status = require_ 'view.status',
    plugins = require_ 'view.plugins',
    help = require_ 'view.help',
    bouncer = require_ 'view.bouncer',
    buffer = require_ 'view.buffer',
    session = require_ 'view.session',
    channels = require_ 'view.channels',
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
    ncurses.erase(thepad)
    ncurses.erase(inputwin)
    normal(thepad)
    views[view]:render(thepad)
    drawing.draw_status_bar(inputwin)
    ncurses.noutrefresh()
    thepad:pnoutrefresh(0, hscroll, 0, 0, tty_height-1, tty_width-1)
    ncurses.noutrefresh(inputwin)
    ncurses.doupdate()
end

-- Callback Logic =====================================================

local M = {}

local key_handlers = require_ 'handlers.keyboard'
local input_handlers = require_ 'handlers.input'
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

local conn_handlers = {}

function connect()
    objective = 'connect'
    local conn, errmsg =
        snowcone.connect(
        configuration.tls,
        configuration.host,
        configuration.port or configuration.tls and 6697 or 6667,
        configuration.tls_client_cert,
        configuration.tls_client_key,
        configuration.tls_client_password,
        configuration.tls_verify_host,
        configuration.tls_sni_host,
        configuration.socks_host,
        configuration.socks_port,
        configuration.socks_username,
        configuration.socks_password,
        configuration.bind_host,
        configuration.bind_port,
        function(event, arg)
            conn_handlers[event](arg)
        end)
    if conn then
        status('irc', 'connecting')
        irc_state = Irc(conn)
    else
        status('irc', 'failed to connect: %s', errmsg)
    end
end

-- a global allows these to be replaced on a live connection
irc_handlers = require_ 'handlers.irc'

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
    if objective ~= 'connect' then
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

    if objective == 'exit' then
        snowcone.shutdown()
    elseif objective == 'connect' then
        reconnect_timer = snowcone.newtimer()
        reconnect_timer:start(1000, function()
            reconnect_timer = nil
            connect()
        end)
    end
end

function conn_handlers.BAD(code)
    status('irc', 'message parse error: %d', code)
end

function disconnect()
    if irc_state then
        irc_state:close()
        irc_state = nil
    end
end

function quit()
    if tick_timer then
        tick_timer:cancel()
        tick_timer = nil
    end
    if reconnect_timer then
        reconnect_timer:cancel()
        reconnect_timer = nil
    end
    if irc_state then
        objective = 'exit'
        disconnect()
    else
        if objective ~= 'exit' then
            objective = 'exit'
            snowcone.shutdown()
        end
    end
end

function set_talk_target(target)
    if target ~= talk_target then
        talk_target_old = talk_target
        talk_target = target
    end
end

local function startup()
    -- initialize global variables
    for k,v in pairs(defaults) do
        if not _G[k] then
            _G[k] = v
        end
    end

    commands = require_ 'handlers.commands'

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
    local configuration_schema = {
        type = 'table',
        fields = {
            host                = {type = 'string', required = true},
            port                = {type = 'number'},
            socks_host          = {type = 'string'},
            socks_port          = {type = 'number'},
            socks_username      = {type = 'string'},
            socks_password      = {type = 'string'},
            bind_host           = {type = 'string'},
            bind_port           = {type = 'number'},
            tls                 = {type = 'boolean'},
            tls_client_cert     = {type = 'string'},
            tls_client_key      = {type = 'string'},
            tls_client_password = {type = 'string'},
            tls_verify_host     = {type = 'string'},
            tls_sni_host        = {type = 'string'},
            fingerprint         = {type = 'string'},
            nick                = {type = 'string', pattern = '^[^\n\r\x00 ]+$', required = true},
            user                = {type = 'string', pattern = '^[^\n\r\x00 ]+$'},
            gecos               = {type = 'string', pattern = '^[^\n\r\x00]+$'},
            passuser            = {type = 'string', pattern = '^[^\n\r\x00:]*$'},
            pass                = {type = 'string', pattern = '^[^\n\r\x00]*$'},
            oper_username       = {type = 'string', pattern = '^[^\n\r\x00 ]+$'},
            oper_password       = {type = 'string', pattern = '^[^\n\r\x00]*$'},
            challenge_key       = {type = 'string'},
            challenge_password  = {type = 'string'},
            plugin_dir          = {type = 'string'},
            plugins             = {type = 'table', elements = {type = 'string', required = true}},
            notification_module = {type = 'string'},
            capabilities        = {
                type = 'table',
                elements = {type = 'string', pattern = '^[^\n\r\x00 ]+$', required = true}
            },
            mention_patterns    = {
                type = 'table',
                elements = {type = 'string', required = true}
            },
            sasl_automatic      = {
                type = 'table',
                elements = {type = 'string', required = true}
            },
            sasl_credentials    = {
                type = 'table',
                assocs = {
                    type = 'table',
                    fields = {
                        mechanism   = {type = 'string', required = true},
                        username    = {type = 'string'},
                        password    = {type = 'string'},
                        key         = {type = 'string'},
                        authzid     = {type = 'string'},
            }}},
        }
    }
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
            end
            draw()
        end
        tick_timer:start(1000, cb)
    end

    if objective == 'connect' and not irc_state and configuration.host then
        connect()
    end
end

local success, error_message = pcall(startup)
if not success then
    status('startup', 'Error: %s', error_message)
    set_view 'status'
    draw()
end
