/**
 * @file mybase64.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Base64 encoding and decoding
 *
 */
#pragma once

#include <cstddef>
#include <string_view>

namespace base64 {

/**
 * @brief Calculate the size of the buffer needed to encode a base64 string
 * 
 * @param len Length of the input string
 * @return size_t Size of the output buffer needed for base64 encoding
 */
inline constexpr auto encoded_size(std::size_t const len) -> std::size_t
{
    return (len + 2) / 3 * 4;
}

/**
 * @brief Calculate the size of the buffer needed to decode a base64 string
 * 
 * @param len Length of the input base64 string
 * @return size_t Size of the output buffer needed for base64 decoding
 */
inline constexpr auto decoded_size(std::size_t const len) -> std::size_t
{
    return (len + 3) / 4 * 3;
}

/**
 * @brief Encode a string into base64
 * 
 * @param input input text
 * @param output Target buffer for encoded value
 */
auto encode(std::string_view input, char* output) -> void;

/**
 * @brief Decode a base64 encoded string
 *
 * @param input Base64 input text
 * @param output Target buffer for decoded value
 * @return pointer to end of output on success
 */
auto decode(std::string_view input, char* output) -> char*;

} // namespace base64
