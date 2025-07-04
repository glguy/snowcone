#include "mybase64.hpp"

#include "base64.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <iterator>

namespace {

/**
 * @brief Lua binding for Base64 decoding.
 *
 * Decodes the given Base64 string into its original binary form.
 * On success, it pushes the decoded string onto the Lua stack.
 * On failure (invalid Base64 input), returns 0 values.
 *
 * param:     string input   Base64-encoded string to decode
 * return[1]: string decoded string
 * return[2]: nil    failure indicator
 *
 * @param L Lua state
 * @return int 1
 */
auto l_from_base64(lua_State* const L) -> int
{
    std::size_t len;
    auto const input_ptr = luaL_checklstring(L, 1, &len);
    std::string_view input { input_ptr, len };

    auto const outlen = base64::decoded_size(input.size());

    luaL_Buffer B;
    auto const output_first = luaL_buffinitsize(L, &B, outlen);
    auto const output_last = base64::decode(input, output_first);
    if (output_last)
    {
        luaL_pushresultsize(&B, std::distance(output_first, output_last));
        return 1;
    }
    else
    {
        luaL_pushfail(L);
        return 1;
    }
}


/**
 * @brief Lua binding for Base64 encoding.
 *
 * Encodes the given string into Base64 format.
 * On success, it pushes the Base64-encoded string onto the Lua stack.
 *
 * param:     string input   input string to encode
 * return:    string output  Base64-encoded string
 *
 * @param L Lua state
 * @return int 1
 */
auto l_to_base64(lua_State* const L) -> int
{
    std::size_t len;
    auto const input_ptr = luaL_checklstring(L, 1, &len);
    std::string_view input { input_ptr, len };
    
    auto const outlen = base64::encoded_size(input.size());

    luaL_Buffer B;
    auto const output = luaL_buffinitsize(L, &B, outlen);
    base64::encode(input, output);
    luaL_pushresultsize(&B, outlen);

    return 1;
}

} // namespace

extern "C" auto luaopen_mybase64(lua_State* const L) -> int
{
    static const luaL_Reg M[] {
        {"from_base64", l_from_base64},
        {"to_base64", l_to_base64},
        {}
    };

    luaL_newlib(L, M);
    return 1;
}