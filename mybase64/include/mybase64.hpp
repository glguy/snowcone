/**
 * @file mybase64.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Base64 encoding and decoding
 * 
 */
#pragma once

#include <cstddef>

void mybase64_encode(char const* input, std::size_t len, char* output);

/**
 * @brief Decode a base64 encoded string
 * 
 * @param input Base64 input text
 * @param len Length of input
 * @param output Target buffer for decoded value
 * @param outlen Output parameter for decoded length
 * @return true success
 * @return false failure
 */
bool mybase64_decode(char const* input, std::size_t len, char* output, std::size_t* outlen);
