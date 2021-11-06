return {
ignore = { "212/self" },
std = "lua53+main+snowcone",
stds = {
    snowcone = {
        read_globals = {
            snowcone = {
              fields = {"to_base64", "from_base64", "send_irc", "dnslookup", "pton", "shutdown", "newtimer",
                "newwatcher", "setmodule", "raise", "xor_strings", "isalnum" },
            },
        },
    },
    main = {
        read_globals = {"tty_height", "tty_width", "configuration", "mygeoip", "ncurses" },
        globals = {
            -- general functionality
            "require_", "next_view", "prev_view", "entry_to_kline",
            "add_network_tracker", "quit", "entry_to_unkline",
            "reset_filter", "initialize", "counter_sync_commands",

            -- global client state
            "irc_state",  "status_message", "input_mode", "servers",
            "view", "views", "uptime", "liveness", "scroll", "editor",
            "uv_resources", "filter", "main_views", "new_channels",
            "focus",

            -- global load bar state
            "trust_uname", "show_reasons", "kline_duration",
            "staged_action", "kline_reason", "kline_reasons", "kline_durations",

            -- connection tracking view
            "users", "exits",
            "conn_filter", "server_filter", "highlight", "highlight_plain",

            -- server tracking view
            "links", "upstream", "population", "conn_tracker", "exit_tracker", "versions",
            "server_ordering", "server_descending", "mrs", "uptimes",

            -- kline load view
            "kline_tracker",

            -- filter load view
            "filter_tracker",

            -- network tracker view
            "net_trackers",

            -- IRC console view
            "messages",

            -- Bans list view
            "klines", "watches",

            -- Rendering
            "draw_load", "add_click", "add_button", "draw_buttons", "draw_global_load",
            "add_population", "draw",

            -- ncurses helpers
            "addstr", "mvaddstr",
            "bold", "bold_", "underline", "underline_", "normal", "reversevideo", "reversevideo_",
            "red", "green", "cyan", "black", "yellow", "magenta", "white", "blue",
            },
        },
    },
}
