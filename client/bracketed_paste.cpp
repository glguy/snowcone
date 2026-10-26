#include "bracketed_paste.hpp"

#include <ncurses.h>

#include <cstdio>

auto BracketedPaste::enable() -> void
{
    fputs("\x1b[?2004h", stdout); // enable bracketed paste
    fputs("\x1b[?1004h", stdout); // enable focus reporting
    fflush(stdout);
}
auto BracketedPaste::install() -> void
{
    define_key("\x1b[200~", start_paste);
    define_key("\x1b[201~", end_paste);
    define_key("\x1b[I", focus_gained);
    define_key("\x1b[O", focus_lost);
}
auto BracketedPaste::disable() -> void
{
    fputs("\x1b[?1004l", stdout); // disable focus reporting
    fputs("\x1b[?2004l", stdout); // disable bracketed paste
    fflush(stdout);
}
