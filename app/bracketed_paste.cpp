#include "bracketed_paste.hpp"

#include <curses.h>

namespace bracketed_paste {
    auto enable(FILE* const tty) -> void {
        fputs("\x1b[?2004h", tty);
        fflush(tty);
    }
    auto disable(FILE* const tty) -> void {
        fputs("\x1b[?2004l", tty);
        fflush(tty);
    }
    auto install() -> void {
        define_key("\x1b[200~", start_paste);
        define_key("\x1b[201~", end_paste);
    }
}
