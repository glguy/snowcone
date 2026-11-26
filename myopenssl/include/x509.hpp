#pragma once

// Lua x509 userdata wrapping an OpenSSL X509 certificate.

#include <openssl/x509.h>

struct lua_State;

namespace myopenssl {
/// Lua myopenssl.new_x509: see the LDoc in myopenssl.cpp.
auto l_new_x509(lua_State*) -> int;
/// Lua myopenssl.read_x509: see the LDoc in myopenssl.cpp.
auto l_read_x509(lua_State*) -> int;
/// The open certificate at arg, or raise an argument error. Borrowed: the
/// userdata keeps ownership, so up-ref it to keep it past the userdata's
/// lifetime.
auto check_x509(lua_State* const L, int const arg) -> X509*;
/// The certificate at arg, or null if it isn't one or is closed. Never raises.
auto test_x509(lua_State* L, int arg) -> X509*;
}
