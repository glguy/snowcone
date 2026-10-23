#include "socks5.hpp"

#include <boost/asio.hpp>

#include <iterator>
#include <stdexcept>
#include <vector>

namespace socks5 {

SocksErrCategory const theSocksErrCategory;

char const* SocksErrCategory::name() const noexcept
{
    return "socks5";
}

std::string SocksErrCategory::message(int ev) const
{
    switch (static_cast<SocksErrc>(ev))
    {
    case SocksErrc::Succeeded:
        return "succeeded";
    case SocksErrc::GeneralFailure:
        return "general SOCKS server failure";
    case SocksErrc::NotAllowed:
        return "connection not allowed by ruleset";
    case SocksErrc::NetworkUnreachable:
        return "network unreachable";
    case SocksErrc::HostUnreachable:
        return "host unreachable";
    case SocksErrc::ConnectionRefused:
        return "connection refused";
    case SocksErrc::TtlExpired:
        return "TTL expired";
    case SocksErrc::CommandNotSupported:
        return "command not supported";
    case SocksErrc::AddressNotSupported:
        return "address type not supported";
    case SocksErrc::WrongVersion:
        return "bad server protocol version";
    case SocksErrc::NoAcceptableMethods:
        return "server rejected authentication methods";
    case SocksErrc::AuthenticationFailed:
        return "server rejected authentication";
    case SocksErrc::UnsupportedEndpointAddress:
        return "server sent unknown endpoint address";
    case SocksErrc::DomainTooLong:
        return "domain name too long";
    case SocksErrc::UsernameTooLong:
        return "username too long";
    case SocksErrc::PasswordTooLong:
        return "password too long";
    default:
        return "(unrecognized error)";
    }
}

auto make_error_code(SocksErrc const err) -> boost::system::error_code
{
    return boost::system::error_code{int(err), theSocksErrCategory};
}

} // namespace socks5

namespace std {
template<>
struct is_error_code_enum<socks5::SocksErrc> : true_type {};
}

