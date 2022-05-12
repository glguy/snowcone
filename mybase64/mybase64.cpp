#include "mybase64.hpp"

#include <cstdint>
#include <string_view>

static_assert(CHAR_BIT == 8);

void mybase64_encode(char const* input, std::size_t len, char* output)
{
  static char const* const alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789+/";

  auto cursor = reinterpret_cast<unsigned char const*>(input);
  auto const end = cursor + len;

  while (end - cursor >= 3)
  {
    uint32_t buffer = *cursor++;
    buffer <<= 8; buffer |= *cursor++;
    buffer <<= 8; buffer |= *cursor++;

    *output++ = alphabet[(buffer >> 6 * 3) % 64];
    *output++ = alphabet[(buffer >> 6 * 2) % 64];
    *output++ = alphabet[(buffer >> 6 * 1) % 64];
    *output++ = alphabet[(buffer >> 6 * 0) % 64];
  }

  if (cursor < end)
  {
    uint32_t buffer = *cursor++; buffer <<= 8;
    if (cursor < end) buffer |= *cursor; buffer <<= 2;

    *output++ = alphabet[(buffer >> 12) % 64];
    *output++ = alphabet[(buffer >> 6) % 64];
    *output++ = cursor < end ? alphabet[(buffer % 64)] : '=';
    *output++ = '=';
  }
  *output = '\0';
}

bool mybase64_decode(char const* input, std::size_t len, char* output, std::size_t* outlen)
{
    static constexpr int8_t const alphabet_values[] = {
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1, 0x3e,   -1,   -1,   -1, 0x3f,
      0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b,
      0x3c, 0x3d,   -1,   -1,   -1,   -1,   -1,   -1,
        -1, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
      0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
      0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16,
      0x17, 0x18, 0x19,   -1,   -1,   -1,   -1,   -1,
        -1, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
      0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
      0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30,
      0x31, 0x32, 0x33,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
        -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
    };

    uint32_t buffer = 1;
    char* cursor = output;

    for (char c : std::string_view {input, len}) {
        int8_t const value = alphabet_values[uint8_t(c)];
        if (-1 == value) continue;

        buffer <<= 6; buffer |= value;

        if (buffer >= 1<<24) {
            *cursor++ = buffer >> (8*2);
            *cursor++ = buffer >> (8*1);
            *cursor++ = buffer >> (8*0);
            buffer = 1;
        }
    }

    if (buffer >= 1<<18) {
      *cursor++ = buffer >> 10;
      *cursor++ = buffer >> 2;
    } else if (buffer >= 1<<12) {
      *cursor++ = buffer >> 4;
    } else if (buffer != 1) {
      return false;
    }
    *outlen = cursor - output;
    return true;
}
