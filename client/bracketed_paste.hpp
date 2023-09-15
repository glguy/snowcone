#pragma once
/**
 * @file bracketed_paste.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Bracketed paste logic
 *
 */

struct BracketedPaste
{
    BracketedPaste();
    ~BracketedPaste();
    static auto install() -> void;
    static int const start_paste = 01000;
    static int const end_paste = 01001;
    static int const focus_gained = 01002;
    static int const focus_lost = 01003;
};
