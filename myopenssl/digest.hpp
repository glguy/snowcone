#pragma once

// Lua digest userdata wrapping a static OpenSSL EVP_MD.

struct lua_State;

#include <openssl/evp.h>

namespace myopenssl {

/// Lua myopenssl.get_digest: see the LDoc in myopenssl.cpp.
auto l_get_digest(lua_State* L) -> int;
/// The digest at arg, or raise an argument error. The EVP_MD is OpenSSL's
/// static object and is never freed.
auto check_digest(lua_State* L, int arg) -> EVP_MD const*;

} // namespace myopenssl
