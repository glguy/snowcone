#pragma once
/**
 * @file bracketed_paste.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Bracketed paste logic
 *
 */

struct BracketedPaste
{
    /// Define the key codes below for the paste and focus sequences
    static auto install() -> void;
    /// Turn on bracketed paste and focus reporting
    static auto enable() -> void;
    /// Turn off bracketed paste and focus reporting; safe to call more than once
    static auto disable() -> void;
    static constexpr int start_paste = 01000;
    static constexpr int end_paste = 01001;
    static constexpr int focus_gained = 01002;
    static constexpr int focus_lost = 01003;
};
