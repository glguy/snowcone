return {
ignore = { "212/self" },
std = "lua53+snowcone+pl",
stds = {
    pl = {
        globals = {
            path = {fields = {"isdir", "isfile", "getsize", "exists", "getatime", "getmtime", "getctime",
                    "splitpath", "abspath", "splittext", "dirname", "basename", "extension",
                    "isabs", "join", "normcase", "normpath", "relpath", "expanduser", "tmpname",
                    "common_prefix", "package_path", }},
            file = {fields = {"read", "write", "copy", "move", "access_time", "creation_time",
                    "modified_time", "delete",}},
            Set  = {"Set", "values", "map", "union", "intersection", "difference", "issubset",
                    "isempty", "isdisjoint", "len"},
            tablex = {fields = {"update", "keys"}},
            pretty = {fields = {"read", "load", "write", "dump", "number"}},
        },
    },
    snowcone = {
        read_globals = {"newtimer", "setmodule", "tty_height", "tty_width",
            "configuration", "to_base64", "dnslookup", "mygeoip",
            "newwatcher", "shutdown", "pton", "ncurses",
            },
        globals = {
            "irc_state", "send_irc", "require_", "status_message", "views",

            "primary_hub", "uptime", "trust_uname", "show_reasons", "kline_duration",
            "staged_action", "kline_reason", "scroll", "history", "mrs", "server_ordering",
            "server_descending",

            "links", "upstream", "population", "conn_tracker", "exit_tracker",
            "kline_tracker", "filter_tracker", "net_trackers",
            "messages", "messages_n", "klines",
            "users", "clicon_n",
            "exits", "cliexit_n",

            "kline_reasons", "kline_durations", "entry_to_kline",
            "unkline_ready", "show_entry", "kline_ready", "entry_to_unkline",

            "conn_filter", "server_filter", "filter",
            "reset_filter", "initialize",
            "highlight", "highlight_plain",

            "draw_load", "add_click", "add_button", "draw_buttons", "draw_global_load",
            "add_population", "draw", "counter_sync_commands",

            "addstr", "mvaddstr",
            "bold", "bold_", "underline", "underline_", "normal", "reversevideo", "reversevideo_",
            "red", "green", "cyan", "black", "yellow", "magenta", "white", "blue",

            "view", "views",

            "NetTracker", "add_network_tracker",

            "irc_authentication", "ip_org", "servers", "scrub",

            "quit", "uv_resources",
            },
        },
    },
}
