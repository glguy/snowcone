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
    value.resize(6 + n);
    base64::encode(payload, &value[6]);

    return value;
}

}

namespace httpconnect {

auto detail::authority(std::string_view const host, uint16_t const port) -> std::string
{
    std::string result;

    // Hostnames can't contain ':', so this is an IPv6 literal
    if (host.find(':') != std::string_view::npos)
    {
        result += '[';
        for (auto const c : host)
        {
            result += c;
            if (c == '%')
            {
                result += "25";
            }
        }
        result += ']';
    }
    else
    {
        result += host;
    }

    result += ':';
    result += std::to_string(port);
    return result;
}

HttpErrCategory const theHttpErrCategory;

char const* HttpErrCategory::name() const noexcept
{
    return "httpconnect";
}

std::string HttpErrCategory::message(int ev) const
{
    return std::string{"HTTP "} + std::to_string(ev);
}

namespace detail {
    auto make_http_error(int status) -> boost::system::error_code
    {
        return boost::system::error_code{status, theHttpErrCategory};
    }
}

}