#define _XOPEN_SOURCE 600
#define _XOPEN_SOURCE_EXTENDED
#define _DARWIN_C_SOURCE

#include "app.hpp"
#include "configuration.hpp"
#include "irc.hpp"

#include <ncurses.h>

#include <clocale>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <sys/errno.h>
#include <system_error>
#include <unistd.h>

namespace {

struct FILECloser {
    void operator()(FILE* file) { fclose(file); }
};
struct SCREENCloser {
    void operator()(SCREEN* scr) { delscreen(scr); }
};

struct Ncurses {
    std::unique_ptr<FILE, FILECloser> tty;
    std::unique_ptr<SCREEN, SCREENCloser> scr;
};

Ncurses initialize_terminal() {
    Ncurses result {};

    setlocale(LC_ALL, "");

    result.tty = decltype(result.tty)(fopen("/dev/tty", "w"));
    if (!result.tty) {
        throw std::system_error(errno, std::generic_category());
    }

    result.scr = decltype(result.scr)(newterm(nullptr, result.tty.get(), stdin));
    if (!result.scr) {
        throw std::runtime_error("newterm");
    }

    start_color();
    use_default_colors();
    nodelay(stdscr, TRUE); /* nonblocking input reads */
    raw(); /* pass through all they keys */
    noecho(); /* no echo input to screen */
    nonl(); /* no newline on pressing return */
    intrflush(stdscr, FALSE);
    keypad(stdscr, TRUE); /* process keyboard input escape sequences */
    curs_set(0); /* no cursor */
    mousemask(BUTTON1_CLICKED, nullptr);
    set_escdelay(25);
    endwin();

    return result;
}

} // namespace

/* MAIN **************************************************************/

int main(int argc, char *argv[])
{
    configuration cfg = load_configuration(argc, argv);

    auto nc = initialize_terminal();

    app a {&cfg};
    a.init();

    if (*cfg.irc_socat != '\0') {
        start_irc(&a);
    }
    
    a.run();

    endwin();
    a.destroy();
    return 0;
}
