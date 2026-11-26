#pragma once

// Lua bignum userdata wrapping an OpenSSL BIGNUM.

#include <openssl/bn.h>

struct lua_State;

namespace myopenssl {
/// Push an empty bignum userdata and return its slot. A BIGNUM stored there
/// is owned by the userdata (freed by its __gc or __close), so store a new
/// one there before anything else can raise. Empty, it reads as "bignum
/// already closed".
auto push_bignum(lua_State*) -> BIGNUM*&;
/// Push a bignum userdata holding a new BIGNUM, zero, and return it.
/// Raises an OpenSSL error if it can't be allocated.
auto new_bignum(lua_State*) -> BIGNUM*;
/// Lua myopenssl.bignum: see the LDoc in myopenssl.cpp.
auto l_bignum(lua_State*) -> int;
}
