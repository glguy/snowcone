/**
 * @file base64.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Base64 encoding and decoding
 *
 * Standard RFC 4648 alphabet ('+', '/') with '=' padding. Callers supply
 * the output buffers, sized with encoded_size() and decoded_size(); nothing
 * is allocated and no NUL terminator is written.
 */
#pragma once

#include <cstddef>
#include <string_view>

namespace base64 {

/**
 * @brief Exact number of characters encode() writes for an input of len bytes
 *
 * @param len Length of the raw input in bytes
 * @return size_t Length of the padded Base64 output (a multiple of 4)
 */
inline constexpr auto encoded_size(std::size_t const len) -> std::size_t
{
    return (len + 2) / 3 * 4;
}

/**
 * @brief Upper bound on the bytes decode() writes for an input of len characters
 *
 * The actual decoded length may be smaller, since padding and other
 * non-alphabet characters produce no output.
 *
 * @param len Length of the Base64 input in characters
 * @return size_t Minimum safe size of the decode() output buffer
 */
inline constexpr auto decoded_size(std::size_t const len) -> std::size_t
{
    return (len + 3) / 4 * 3;
}

/**
 * @brief Encode arbitrary bytes as padded Base64
 *
 * Writes exactly encoded_size(input.size()) characters and no terminator.
 *
 * @param input Raw bytes to encode
 * @param output Target buffer of at least encoded_size(input.size()) bytes
 */
auto encode(std::string_view input, char* output) -> void;

/**
 * @brief Decode a base64 encoded string
 *
 * Characters outside the Base64 alphabet, including '=' padding, are
 * skipped wherever they appear. Decoding fails only when the number of
 * alphabet characters leaves a single character after the last complete
 * 4-character group (count % 4 == 1); unused low bits in a final partial
 * group are ignored rather than rejected. On failure, output may already
 * have been partially written.
 *
 * @param input Base64 input text
 * @param output Target buffer for decoded value, at least
 *               decoded_size(input.size()) bytes
 * @return pointer to end of output on success, nullptr on failure
 */
auto decode(std::string_view input, char* output) -> char*;

} // namespace base64
