#include "base64.hpp"

#include <array>
#include <climits>
#include <cstdint>
#include <iterator>
#include <string_view>

namespace base64 {

namespace {

    constexpr auto alphabet = std::array<char, 64>{
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
        'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
        'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
        'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/'
    };

    constexpr auto alphabet_values = []() constexpr -> std::array<std::int8_t, 256> {
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

    std::uint32_t buffer;

    auto const extract = [&buffer](int const i) -> char {
        return alphabet[0x3f & buffer >> 6 * i];
    };

    while (std::distance(cursor, end) >= std::ptrdiff_t(3))
    {
        buffer  = static_cast<std::uint8_t>(*cursor++) << 8 * 2;
        buffer |= static_cast<std::uint8_t>(*cursor++) << 8 * 1;
        buffer |= static_cast<std::uint8_t>(*cursor++) << 8 * 0;

        *output++ = extract(3);
        *output++ = extract(2);
        *output++ = extract(1);
        *output++ = extract(0);
    }

    if (cursor < end)
    {
        buffer = static_cast<std::uint8_t>(*cursor++) << (8 * 2 - 6);
        if (cursor < end)
            buffer |= static_cast<std::uint8_t>(*cursor) << (8 * 1 - 6);

        *output++ = extract(2);
        *output++ = extract(1);
        *output++ = cursor < end ? extract(0) : '=';
        *output++ = '=';
    }
}

auto decode(std::string_view const input, char* output) -> char*
{
    std::uint32_t buffer = 1;

    auto const filled = [&buffer](int const i) -> bool {
        return buffer >> 6 * i;
    };

    for (auto const c : input)
    {
        if (auto const value = alphabet_values[static_cast<std::uint8_t>(c)]; -1 != value)
        {
            buffer = buffer << 6 | value;
            if (filled(4))
            {
                *output++ = buffer >> 8 * 2;
                *output++ = buffer >> 8 * 1;
                *output++ = buffer >> 8 * 0;
                buffer = 1;
            }
        }
    }

    if (filled(3))
    {
        buffer <<= 6 * 1;
        *output++ = buffer >> 8 * 2;
        *output++ = buffer >> 8 * 1;
    }
    else if (filled(2))
    {
        buffer <<= 6 * 2;
        *output++ = buffer >> 8 * 2;
    }
    else if (filled(1))
    {
        return nullptr; // invalid base64 input - report failure
    }
    return output;
}

} // namespace
