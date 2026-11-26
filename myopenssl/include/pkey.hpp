#pragma once

// Lua pkey userdata wrapping an OpenSSL EVP_PKEY.

#include <openssl/evp.h>

struct lua_State;

namespace myopenssl {

/// Lua myopenssl.read_raw: see the LDoc in myopenssl.cpp.
auto l_read_raw(lua_State*) -> int;
/// Lua myopenssl.read_pem: see the LDoc in myopenssl.cpp.
auto l_read_pem(lua_State*) -> int;
/// Lua myopenssl.gen_pkey: see the LDoc in myopenssl.cpp.
auto l_gen_pkey(lua_State*) -> int;
/// Lua myopenssl.pkey_from_store: see the LDoc in myopenssl.cpp.
auto l_pkey_from_store(lua_State*) -> int;
/// The open key at arg, or raise an argument error. Borrowed: the userdata
/// keeps ownership, so up-ref it to keep it past the userdata's lifetime.
auto check_pkey(lua_State*, int) -> EVP_PKEY*;
/// The key at arg, or null if it isn't one or is closed. Never raises.
auto test_pkey(lua_State*, int) -> EVP_PKEY*;
/// Push an empty pkey userdata and return its slot. A key stored there is
/// owned by the userdata (freed by its __gc or __close), so store a new one
/// there before anything else can raise. Empty, it reads as "pkey already
/// closed".
auto push_evp_pkey(lua_State*) -> EVP_PKEY*&;

} // namespace myopenssl
