#pragma once

#include <cstdio>

namespace bracketed_paste {
    auto enable(FILE* tty) -> void;
    auto disable(FILE* tty) -> void;
    int const start_paste = 01000;
    int const end_paste   = 01001;
    auto install() -> void;
}
