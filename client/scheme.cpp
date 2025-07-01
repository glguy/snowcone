#include "scheme.hpp"

extern "C" {
#include "lauxlib.h"
}

#include <s7.h>
#include <mybase64.hpp>
#include <cstdlib>

namespace {

auto s_from_base64(s7_scheme* sc, s7_pointer args) -> s7_pointer
{
    auto const arg1 = s7_car(args);
    
    auto const input = s7_object_to_c_string(sc, arg1);
    std::string output(mybase64::decoded_size(strlen(input)), '\0');
    auto const start = output.data();
    auto const end_output = mybase64::decode(input, start);
    free(input);
    return s7_make_string_with_length(sc, start, std::distance(start, end_output));
}

auto s_to_base64(s7_scheme* sc, s7_pointer args) -> s7_pointer
{
    auto const arg1 = s7_car(args);
    auto const input = s7_object_to_c_string(sc, arg1);
    
    std::string output(mybase64::encoded_size(strlen(input)), '\0');
    auto const start = output.data();
    mybase64::encode(input, start);
    free(input);
    return s7_make_string_with_length(sc, start, output.size());
}

} // namespace

auto l_scheme(lua_State* const L) -> int
{
    auto const scheme = luaL_checkstring(L, 1);
    
    s7_scheme* const sc = s7_init();
    if (!sc)
    {
        return luaL_error(L, "s7_init failed");
    }
    
    s7_define_function(sc, "from_base64", s_from_base64, 1, 0, false, "Decode a Base64-encoded string");

    auto result = s7_eval_c_string_with_environment(sc, scheme, s7_nil(sc));
    auto output = s7_object_to_c_string(sc, result);
    lua_pushstring(L, output);
    free(output);
    s7_free(sc);

    return 1;
}
