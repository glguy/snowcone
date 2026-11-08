#include "bracketed_paste.hpp"

#include <ncurses.h>

#include <cstdio>

namespace {
// Whether the modes are on, so disable() pops the title stack only once
// for each push
bool enabled = false;
} // namespace

auto BracketedPaste::enable() -> void
{
    if (enabled)
    {
        return;
    }
    enabled = true;
    fputs("\x1b[22;0t", stdout); // save the window title and icon name
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
    if (not enabled)
    {
        return;
    }
    enabled = false;
    fputs("\x1b[?1004l", stdout); // disable focus reporting
    fputs("\x1b[?2004l", stdout); // disable bracketed paste
    fputs("\x1b[23;0t", stdout); // restore the window title and icon name
    fflush(stdout);
}
