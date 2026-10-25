#include "app.hpp"
#include "applib.hpp"
#include "bracketed_paste.hpp"
#include "config.hpp"
#include "safecall.hpp"

#include <ncurses.h>

#include <clocale>
#include <csignal>
#include <cstring>
#include <iostream>
#include <optional>

class NC final
{
    BracketedPaste bp;

public:
    NC()
    {
        setlocale(LC_ALL, "");
        initscr();
        start_color();
        use_default_colors();
        raw(); /* pass through all they keys */
        noecho(); /* no echo input to screen */
        nonl(); /* no newline on pressing return */
        curs_set(0); /* no cursor */
        mousemask(BUTTON1_CLICKED | BUTTON_SHIFT, nullptr);
        set_escdelay(25);
        nodelay(stdscr, TRUE); /* nonblocking input reads */
        intrflush(stdscr, FALSE);
        keypad(stdscr, TRUE); /* process keyboard input escape sequences */
        BracketedPaste::install();
    }

    NC(NC const&) = delete;
    NC(NC&&) = delete;
    auto operator=(NC const&) -> NC& = delete;
    auto operator=(NC&&) -> NC& = delete;

    ~NC()
    {
        endwin();
    }
};

auto main(int argc, char const* argv[]) -> int
{
    // script FILE runs FILE as the main module, so drop the mode word
    auto const script = argc >= 3 and not strcmp("script", argv[1]);
    if (script)
    {
        argc--;
        argv++;
    }

    if (argc < 2 or not strcmp("script", argv[1]))
    {
        std::cerr << "Usage: snowcone MODE [--config=PATH]\n"
                     "  Modes:\n"
                     "    ircc               - chat client\n"
                     "    dashboard          - server notice dashboard\n"
                     "    path/to/init.lua   - arbitrary Lua script\n"
                     "    script FILE [ARGS] - run FILE without a terminal; exits when\n"
                     "                         idle, nonzero after any Lua error\n"
                     " \n"
                     "  --config=PATH        - override configuration file\n"
                     "                         (default ~/.config/snowcone/settings.lua)\n";
        return EXIT_FAILURE;
    }

    // A write to a pipe or socket whose reader is gone reports EPIPE instead
    // of killing the client. Child processes get the default back (process.cpp).
    std::signal(SIGPIPE, SIG_IGN);

    if (not strcmp("dashboard", argv[1]))
    {
        argv[1] = CMAKE_INSTALL_FULL_DATAROOTDIR "/snowcone/dashboard/init.lua";
    }
    else if (not strcmp("ircc", argv[1]))
    {
        argv[1] = CMAKE_INSTALL_FULL_DATAROOTDIR "/snowcone/ircc/init.lua";
    }

    std::optional<NC> nc;
    if (not script)
    {
        nc.emplace();
    }
    auto a = App{argv[1], script};
    auto const L = a.get_lua();

    auto loaded = false;
    try
    {
        prepare_globals(L, argc, argv);
        loaded = a.reload();
        if (loaded)
        {
            a.startup();
        }
    }
    catch (std::exception const& e)
    {
        App::fatal(e.what());
    }

    // A script fails if it couldn't load or any Lua error was reported
    if (script and (not loaded or safecall_failures() > 0))
    {
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
