#include "socks.hpp"

#include <boost/asio.hpp>

#include <array>
#include <iterator>
#include <span>
#include <stdexcept>
#include <tuple>
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

namespace detail
{

auto make_socks_error(SocksErrc const err) -> boost::system::error_code
{
    return boost::system::error_code{int(err), theSocksErrCategory};
}

auto push_host(Host const& host, std::vector<uint8_t> &buffer) -> void
{
    std::visit(overloaded {
        [&buffer](std::string_view const hostname) {
            buffer.push_back(uint8_t(AddressType::DomainName));
            push_buffer(buffer, hostname);
        },
        [&buffer](boost::asio::ip::address const& address){
            if (address.is_v4()) {
                buffer.push_back(uint8_t(AddressType::IPv4));
                push_buffer(buffer, address.to_v4().to_bytes());
            } else if (address.is_v6()) {
                buffer.push_back(uint8_t(AddressType::IPv6));
                push_buffer(buffer, address.to_v6().to_bytes());
            } else {
                throw std::logic_error{"unexpected address type"};
            }
        }},
        host
    );
}

} // namespace detail

} // namespace socks5
