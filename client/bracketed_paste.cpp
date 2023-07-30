#include "bracketed_paste.hpp"

#include <ncurses.h>

BracketedPaste::BracketedPaste()
{
    puts("\x1b[?2004h");
    fflush(stdout);
}
auto BracketedPaste::install() -> void
{
    define_key("\x1b[200~", start_paste);
    define_key("\x1b[201~", end_paste);
}
BracketedPaste::~BracketedPaste()
{
    puts("\x1b[?2004l");
    fflush(stdout);
}
