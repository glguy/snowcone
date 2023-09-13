#include "bracketed_paste.hpp"

#include <ncurses.h>

#include <cstdio>

BracketedPaste::BracketedPaste()
{
    puts("\x1b[?2004h"); // enable bracketed paste
    puts("\x1b[?1004h"); // enable focus reporting
    fflush(stdout);
}
auto BracketedPaste::install() -> void
{
    define_key("\x1b[200~", start_paste);
    define_key("\x1b[201~", end_paste);
    define_key("\x1b[I", focus_gained);
    define_key("\x1b[O", focus_lost);    
}
BracketedPaste::~BracketedPaste()
{
    puts("\x1b[?1004l"); // disable bracketed paste
    puts("\x1b[?2004l"); // disable bracketed paste
    fflush(stdout);
}
