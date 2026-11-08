#pragma once
/**
 * @file bracketed_paste.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Terminal modes: bracketed paste, focus reporting and the saved
 * window title and icon name
 *
 */

struct BracketedPaste
{
    /// Define the key codes below for the paste and focus sequences
    static auto install() -> void;
    /// Save the window title and icon name and turn on bracketed paste and
    /// focus reporting; does nothing while they are on
    static auto enable() -> void;
    /// Turn off bracketed paste and focus reporting and restore the window
    /// title and icon name; does nothing while they are off
    static auto disable() -> void;
    static constexpr int start_paste = 01000;
    static constexpr int end_paste = 01001;
    static constexpr int focus_gained = 01002;
    static constexpr int focus_lost = 01003;
};
