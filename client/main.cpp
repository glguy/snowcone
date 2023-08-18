#include "app.hpp"
#include "applib.hpp"
#include "bracketed_paste.hpp"
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

auto main(int argc, char *argv[]) -> int
{
    if (argc < 2)
    {
        return 1;
    }

    auto nc = NC{};
    auto a = App{};

    prepare_globals(a.L, argc, argv);
    if (load_logic(a.L, argv[1])) {
        a.startup();
    }
}
