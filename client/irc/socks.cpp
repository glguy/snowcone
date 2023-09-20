#include "socks.hpp"

#include <boost/asio.hpp>
#include <boost/endian.hpp>

#include <array>
#include <iterator>
#include <vector>

namespace socks5
{

const SocksErrCategory theSocksErrCategory;

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

namespace detail
{

auto push_host(Host const& host, std::vector<uint8_t> &buffer) -> void
{
    switch (host.index()) {
        case 0: {
            auto const& hostname = std::get<0>(host);
            buffer.push_back(uint8_t(AddressType::DomainName));
            buffer.push_back(hostname.size());
            std::copy(hostname.begin(), hostname.end(), std::back_inserter(buffer));
            break;
        }
        case 1: {
            auto const& address = std::get<1>(host);
            if (address.is_v4()) {
                buffer.push_back(uint8_t(AddressType::IPv4));
                auto const bytes = address.to_v4().to_bytes();
                std::copy(bytes.begin(), bytes.end(), std::back_inserter(buffer));
            } else {
                buffer.push_back(uint8_t(AddressType::IPv6));
                auto const bytes = address.to_v6().to_bytes();
                std::copy(bytes.begin(), bytes.end(), std::back_inserter(buffer));
            }
        }
    }
}

} // namespace detail

} // namespace socks5
