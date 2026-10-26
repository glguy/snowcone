-- HUB is the only global hub creates (design section 3)
return {
std = "lua54+snowcone",
allow_defined = false,
allow_defined_top = false,
globals = {"HUB"},
stds = {
    snowcone = {
        read_globals = {
            snowcone = {
                fields = {"to_base64", "from_base64", "dnslookup", "pton", "shutdown", "newtimer",
                    "setmodule", "raise", "isalnum", "irccase", "parse_irc", "parse_irc_tags",
                    "SIGINT", "SIGTSTP", "connect", "execute", "time", "parse_toml",
                    "start_input", "stop_input", "start_httpd"},
            },
            "tty_height", "tty_width", "ncurses",
            "myopenssl", "mybase64", "mytoml",
            "mystringprep", "hsfilter", "myarchive", "mygeoip",
        },
    },
},
}
