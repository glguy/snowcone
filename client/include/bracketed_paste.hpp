#pragma once

#include <cstdio>

struct BracketedPaste
{
    BracketedPaste();
    auto install() -> void;
    ~BracketedPaste();
    static int const start_paste = 01000;
    static int const end_paste = 01001;
};
