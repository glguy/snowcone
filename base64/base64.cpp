#include "base64.hpp"

#include <array>
#include <climits>
#include <cstdint>
#include <string_view>

namespace base64 {

namespace {

    constexpr std::array<char, 64> alphabet{
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
        'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
        'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
        'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/'
    };

    constexpr std::array<std::int8_t, 256> alphabet_values = []() constexpr {
        std::array<std::int8_t, 256> result;
        result.fill(-1);
        std::int8_t v = 0;
        for (auto const k : alphabet)
        {
            result[k] = v++;
        }
        return result;
    }();

}

static_assert(CHAR_BIT == 8);

auto encode(std::string_view const input, char* output) -> void
{
    auto cursor = std::begin(input);
    auto const end = std::end(input);

    while (end - cursor >= 3)
    {
        std::uint32_t buffer = std::uint8_t(*cursor++);
        buffer <<= 8;
        buffer |= std::uint8_t(*cursor++);
        buffer <<= 8;
        buffer |= std::uint8_t(*cursor++);

        *output++ = alphabet[(buffer >> 6 * 3) % 64];
        *output++ = alphabet[(buffer >> 6 * 2) % 64];
        *output++ = alphabet[(buffer >> 6 * 1) % 64];
        *output++ = alphabet[(buffer >> 6 * 0) % 64];
    }

    if (cursor < end)
    {
        std::uint32_t buffer = std::uint8_t(*cursor++) << 10;
        if (cursor < end)
            buffer |= std::uint8_t(*cursor) << 2;

        *output++ = alphabet[(buffer >> 12) % 64];
        *output++ = alphabet[(buffer >> 6) % 64];
        *output++ = cursor < end ? alphabet[(buffer % 64)] : '=';
        *output++ = '=';
    }
    *output = '\0';
}

auto decode(std::string_view const input, char* output) -> char*
{
    std::uint32_t buffer = 1;

    for (auto const c : input)
    {
        if (auto const value = alphabet_values[uint8_t(c)]; -1 != value)
        {
            buffer = (buffer << 6) | value;
            if (buffer & 1 << 6 * 4)
            {
                *output++ = buffer >> 16;
                *output++ = buffer >> 8;
                *output++ = buffer >> 0;
                buffer = 1;
            }
        }
    }

    if (buffer & 1 << 6 * 3)
    {
        *output++ = buffer >> 10;
        *output++ = buffer >> 2;
    }
    else if (buffer & 1 << 6 * 2)
    {
        *output++ = buffer >> 4;
    }
    else if (buffer & 1 << 6 * 1)
    {
        return nullptr;
    }
    return output;
}

} // namespace
