return {
ignore = { "212/self" },
std = "lua54+main+snowcone",
stds = {
    snowcone = {
        read_globals = {
            snowcone = {
              fields = {"to_base64", "from_base64", "dnslookup", "pton", "shutdown", "newtimer",
                "setmodule", "raise", "xor_strings", "isalnum", "irccase", "parse_irc_tags",
                "SIGINT", "SIGTSTP", "connect" },
            },
        },
    },
    main = {
        read_globals = {"tty_height", "tty_width", "mygeoip", "ncurses", "mystringprep", "hsfilter", "myopenssl"},
        globals = {
            "ctrl", "meta", -- functions for defining keyboard handlers
            "require_", -- require function that already reloads
            "next_view", -- function to advance the view
            "prev_view", -- function to retreat the view
            "quit", -- function to shutdown the client
            "conn", -- handle to irc connection
            "disconnect", -- function to disconnect the current IRC connection
            "reset_filter", -- function to reset message filter
            "initialize", -- function to reset all state variable to their defaults

            "tick_timer", -- timer object that runs every second
            "reconnect_timer", -- timer object that fires a reconnect

            -- global client state
            "plugins", -- map of loaded plugins
            "irc_state", -- state of the current IRC connection
            "input_mode", -- current input mode: filter, talk, command
            "view", -- name of the currently rendering view
            "views", -- table of all the available views
            "main_views", -- sequence of views mapped to keyboard shortcuts
            "uptime", -- seconds the client has been open
            "liveness", -- seconds since last message from IRC server
            "scroll", -- number of lines scrolled back
            "editor", -- input textbox state
            "filter", -- pattern used to filter chat messages
            "terminal_focus", -- true when terminal has focus
            "notification_muted", -- notifications we've already seen
            "exiting", -- true when the client is shutting down
            "focus", -- zoomed in message in console

            "commands", -- mapping of the global command handlers
            "irc_handlers", -- mapping of IRC message handlers

            "config_dir", -- path to configuration directory
            "configuration", -- table of user-provided configuration settings

            -- /talk view
            "buffers", -- mapping of all buffers
            "talk_target", -- name of active buffer

            -- /status view
            "status", -- function to record a message in the status buffer
            "status_message", -- current message printed in the status bar
            "status_messages", -- OrderedMap of messages for /status

            -- /console view
            "messages", -- OrderedMap of the recent IRC messages

            -- Rendering
            "add_click", "add_button", "draw",

            -- ncurses helpers
            "addstr", "mvaddstr",
            "bold", "bold_", "underline", "underline_", "normal", "reversevideo", "reversevideo_",
            "red", "green", "cyan", "black", "yellow", "magenta", "white", "blue", "italic", "italic_"
            },
        },
    },
}
