#pragma once
/**
 * @file utf8.hpp
 * @brief Recognizing valid UTF-8, shared by the WebSocket text checks and
 * the escaping of terminal output.
 */

#include <cstddef>
#include <string_view>

/// The length of the valid UTF-8 sequence that `s` starts with, or 0 if it
/// doesn't start with one: an overlong form, a surrogate, a code point past
/// U+10FFFF, or a sequence cut short. `s` must not be empty.
inline auto utf8_sequence_length(std::string_view const s) -> std::size_t
{
    // The byte at i, unsigned
    auto const byte = [s](std::size_t const i) { return static_cast<unsigned char>(s[i]); };
    auto const lead = byte(0);
    if (lead < 0x80)
    {
        return 1;
    }

    // The range of the second byte narrows for the leads that would
    // otherwise allow the forms that aren't valid
    std::size_t length = 0;
    unsigned char low = 0x80, high = 0xbf;
    if (0xc2 <= lead && lead <= 0xdf)
    {
        length = 2;
    }
    else if (0xe0 <= lead && lead <= 0xef)
    {
        length = 3;
        if (lead == 0xe0) low = 0xa0; // overlong
        if (lead == 0xed) high = 0x9f; // surrogate
    }
    else if (0xf0 <= lead && lead <= 0xf4)
    {
        length = 4;
        if (lead == 0xf0) low = 0x90; // overlong
        if (lead == 0xf4) high = 0x8f; // past U+10FFFF
    }
    else
    {
        return 0;
    }

    if (s.size() < length || byte(1) < low || high < byte(1))
    {
        return 0;
    }
    for (std::size_t i = 2; i < length; i++)
    {
        if ((byte(i) & 0xc0) != 0x80)
        {
            return 0;
        }
    }
    return length;
}
