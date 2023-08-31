#include "app.hpp"
#include "applib.hpp"
#include "bracketed_paste.hpp"
#include "config.hpp"
#include "ircmsg.hpp"
#include "safecall.hpp"

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <ncurses.h>

#include <myncurses.h>

#include <clocale>
#include <cstring>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unistd.h>

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
        raw();       /* pass through all they keys */
        noecho();    /* no echo input to screen */
        nonl();      /* no newline on pressing return */
        curs_set(0); /* no cursor */
        mousemask(BUTTON1_CLICKED, nullptr);
        set_escdelay(25);
        nodelay(stdscr, TRUE); /* nonblocking input reads */
        intrflush(stdscr, FALSE);
        keypad(stdscr, TRUE); /* process keyboard input escape sequences */
        bp.install();
    }

    ~NC()
    {
        endwin();
    }
};

auto main(int argc, char const* argv[]) -> int
{
    if (argc < 2)
    {
        std::cerr <<
            "Usage: snowcone MODE [--config=PATH]\n"
            "  Modes:\n"
            "    ircc               - chat client\n"
            "    dashboard          - server notice dashboard\n"
            "    path/to/init.lua   - arbitrary Lua script\n"
            " \n"
            "  --config=PATH        - override configuration file\n"
            "                         (default ~/.config/snowcone/settings.lua)\n";
        return EXIT_FAILURE;
    }

    if (not strcmp("dashboard", argv[1])) {
        argv[1] = CMAKE_INSTALL_FULL_DATAROOTDIR "/snowcone/dashboard/init.lua";
    } else if (not strcmp("ircc", argv[1])) {
        argv[1] = CMAKE_INSTALL_FULL_DATAROOTDIR "/snowcone/ircc/init.lua";
    }

    auto nc = NC{};
    auto a = App{};

    prepare_globals(a.L, argc, argv);
    if (load_logic(a.L, argv[1])) {
        a.startup();
    }
}
