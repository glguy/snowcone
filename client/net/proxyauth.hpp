#pragma once

#include <string>
#include <variant>

namespace socks5 {

struct NoCredential
{
};

struct UsernamePasswordCredential
{
    std::string username;
    std::string password;
};

using Auth = std::variant<NoCredential, UsernamePasswordCredential>;

}
