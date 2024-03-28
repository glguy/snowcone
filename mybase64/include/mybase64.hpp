/**
 * @file mybase64.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Base64 encoding and decoding
 *
 */
#pragma once

#include <cstddef>
#include <string_view>

namespace mybase64
{

inline constexpr auto encoded_size(std::size_t len) -> std::size_t
{
    return (len + 2) / 3 * 4;
}

inline constexpr auto decoded_size(std::size_t len) -> std::size_t
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
 * @param outlen Output parameter for decoded length
 * @return true success
 * @return false failure
 */
auto decode(std::string_view input, char* output, std::size_t* outlen) -> bool;

} // namespace
