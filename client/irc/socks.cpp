#include "socks.hpp"

#include <boost/asio.hpp>
#include <boost/endian.hpp>

#include <array>
#include <iterator>
#include <vector>

namespace socks5
{

const char* SocksErrCategory::name() const noexcept
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
        default:
            return "(unrecognized error)";
    }
}

} // namespace socks5
