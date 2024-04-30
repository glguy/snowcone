#pragma once

struct lua_State;

#include <openssl/evp.h>

namespace myopenssl {

auto l_read_raw(lua_State*) -> int;
auto l_read_pem(lua_State*) -> int;
auto l_gen_pkey(lua_State*) -> int;
auto check_pkey(lua_State*, int) -> EVP_PKEY*;
auto push_evp_pkey(lua_State*, EVP_PKEY*) -> void;

} // namespace myopenssl
