return {
ignore = { "212/self" },
std = "lua53+main+snowcone",
stds = {
    snowcone = {
        read_globals = {
            snowcone = {
              fields = {"to_base64", "from_base64", "send_irc", "dnslookup", "pton", "shutdown", "newtimer",
                "newwatcher", "setmodule", "raise", "xor_strings" },
            },
        },
    },
    main = {
        read_globals = {"tty_height", "tty_width", "configuration", "mygeoip", "ncurses" },
        globals = {
            "irc_state", "require_", "status_message", "input_mode", "servers",
            "view", "views", "uptime", "trust_uname", "show_reasons", "kline_duration",
            "staged_action", "kline_reason", "scroll", "history", "mrs", "server_ordering",
            "server_descending", "liveness", "next_view", "prev_view",

            "links", "upstream", "population", "conn_tracker", "exit_tracker",
            "kline_tracker", "filter_tracker", "net_trackers",
            "messages", "klines", "editor", "watches", "versions",
            "users", "exits",

            "kline_reasons", "kline_durations", "entry_to_kline",
            "show_entry", "entry_to_unkline",

            "conn_filter", "server_filter", "filter", "reset_filter", "initialize",
            "highlight", "highlight_plain",

            "draw_load", "add_click", "add_button", "draw_buttons", "draw_global_load",
            "add_population", "draw", "counter_sync_commands",

            "addstr", "mvaddstr",
            "bold", "bold_", "underline", "underline_", "normal", "reversevideo", "reversevideo_",
            "red", "green", "cyan", "black", "yellow", "magenta", "white", "blue",

            "add_network_tracker", "scrub", "quit", "uv_resources",
            },
        },
    },
}
