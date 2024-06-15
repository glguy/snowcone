return {
ignore = { "212/self" },
std = "lua54+main+snowcone",
stds = {
    snowcone = {
        read_globals = {
            snowcone = {
              fields = {"to_base64", "from_base64", "dnslookup", "pton", "shutdown", "newtimer",
                "setmodule", "raise", "xor_strings", "isalnum", "irccase", "parse_irc_tags",
                "SIGINT", "SIGTSTP", "connect", "parse_irc", "execute", "parse_toml",
                "start_input", "stop_input" },
            },
        },
    },
    main = {
        read_globals = {"tty_height", "tty_width", "mygeoip", "ncurses", "mystringprep", "hsfilter", "myopenssl", "myarchive", "mytoml"},
        globals = {
            "ctrl", "meta", -- functions for defining keyboard handlers
            "next_view", -- function to advance the view
            "prev_view", -- function to retreat the view
            "set_input_mode", -- change input modality
            "quit", -- function to shutdown the client
            "connect",
            "disconnect", -- function to disconnect the current IRC connection
            "reset_filter", -- function to reset message filter
            "initialize", -- function to reset all state variable to their defaults

            "tick_timer", -- timer object that runs every second
            "client_tasks", -- tasks not associated with an irc connection

            -- global client state
            "main_pad", -- bad used for rendering most of the client
            "input_win", -- window used to draw the bottom status bar
            "textbox_offset",
            "textbox_pad",
            "plugin_manager", -- plugin logic
            "irc_state", -- state of the current IRC connection
            "input_mode", -- current input mode: filter, talk, command, password
            "password_task", -- coroutine for password mode
            "password_label", -- label for password mode
            "set_view", -- function to update current view
            "view", -- name of the currently rendering view
            "views", -- table of all the available views
            "main_views", -- sequence of views mapped to keyboard shortcuts
            "uptime", -- seconds the client has been open
            "scroll", -- number of lines scrolled back
            "hscroll", -- columns scrolled right
            "editor", -- input textbox state
            "filter", -- pattern used to filter chat messages
            "terminal_focus", -- true when terminal has focus
            "notification_manager", -- notification logic
            "mode_current", -- connected, connecting, idle
            "mode_target", -- connect, idle, exit
            "mode_timestamp", -- uptime value when mode_current changed
            "focus", -- zoomed in message in console

            "suspend_tty", -- stop drawing and processing input
            "resume_tty", -- resume drawing and processing input

            "commands", -- mapping of the global command handlers
            "irc_handlers", -- mapping of IRC message handlers

            "config_dir", -- path to configuration directory
            "configuration", -- table of user-provided configuration settings

            -- /talk view
            "buffers", -- mapping of all buffers
            "talk_target", -- name of active buffer
            "talk_target_old", -- name of previous buffer
            "set_talk_target", -- function to update talk_target
            
            -- /status view
            "status", -- function to record a message in the status buffer
            "status_message", -- current message printed in the status bar
            "status_messages", -- OrderedMap of messages for /status
            "channel_list",

            -- /console view
            "messages", -- OrderedMap of the recent IRC messages

            -- Rendering
            "add_click", "add_button", "draw",

            -- ncurses helpers
            "bold", "bold_", "underline", "underline_", "normal", "reversevideo", "reversevideo_",
            "red", "green", "cyan", "black", "yellow", "magenta", "white", "blue", "italic", "italic_"
            },
        },
    },
}
