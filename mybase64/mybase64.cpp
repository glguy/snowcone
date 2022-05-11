#include "mybase64.hpp"

#include <cstdint>
#include <locale>
#include <string_view>

void mybase64_encode(char const* input, std::size_t len, char* output)
{
  char const* const alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789+/";
  std::size_t i;

  for (i = 0; i + 3 <= len; i += 3)
  {
    uint32_t const buffer
      = (uint32_t)(unsigned char)input[i + 0] << 8 * 2
      | (uint32_t)(unsigned char)input[i + 1] << 8 * 1
      | (uint32_t)(unsigned char)input[i + 2] << 8 * 0;

    *output++ = alphabet[(buffer >> 6 * 3) % 64];
    *output++ = alphabet[(buffer >> 6 * 2) % 64];
    *output++ = alphabet[(buffer >> 6 * 1) % 64];
    *output++ = alphabet[(buffer >> 6 * 0) % 64];
  }

  if (i < len)
  {
    uint32_t buffer = (uint32_t)(unsigned char)input[i + 0] << (8 * 2);
    if (i + 1 < len)
      buffer |= (uint32_t)(unsigned char)input[i + 1] << (8 * 1);

    *output++ = alphabet[(buffer >> 6 * 3) % 64];
    *output++ = alphabet[(buffer >> 6 * 2) % 64];
    *output++ = i + 1 < len ? alphabet[(buffer >> 6 * 1) % 64] : '=';
    *output++ = '=';
  }
  *output = '\0';
}

static int8_t const alphabet_values[128] = {
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
};

bool mybase64_decode(char const* input, std::size_t len, char* output, std::size_t* outlen)
{
    uint32_t buffer = 0;
    unsigned counter = 0;
    std::size_t length = 0;

    for (char c : std::string_view {input, len}) {
        if (!isascii(c)) continue;

        int8_t const value = alphabet_values[c];
        if (-1 == value) continue;

        buffer = (buffer << 6) | value;

        counter++;

        if (counter == 4) {
            output[length + 0] = buffer >> (8*2);
            output[length + 1] = buffer >> (8*1);
            output[length + 2] = buffer >> (8*0);
            length += 3;
            counter = 0;
            buffer = 0;
        }
    }

    switch (counter)
    {
        default: return false;
        case 0: *outlen = length; return true;
        case 2:
            buffer <<= 6*2;
            output[length + 0] = buffer >> (8*2);
            *outlen = length + 1;
            return true;
        case 3:
            buffer <<= 6*1;
            output[length + 0] = buffer >> (8*2);
            output[length + 1] = buffer >> (8*1);
            *outlen = length + 2;
            return true;
    }
}
