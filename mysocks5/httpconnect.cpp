#include "httpconnect.hpp"

namespace httpconnect {

auto encode_basic_auth(socks5::UsernamePasswordCredential const& auth) -> std::string
{
    std::string payload;
    payload.reserve(auth.username.size() + 1 + auth.password.size());
    payload += auth.username;
    payload += ":";
    payload += auth.password;

    size_t const n = base64::encoded_size(payload.size());
    std::string value;
    value.reserve(6 + n);
    value += "Basic ";
    value.resize(n);
    base64::encode(payload, &value[6]);

    return value;
}

}