#include <stdint.h>

#include "base64.h"

void snowcone_base64(char const* input, size_t len, char *output)
{
  char const* const alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789+/";
  size_t i;

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