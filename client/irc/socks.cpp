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
        default:
            return "(unrecognized error)";
    }
}

namespace detail
{

template<class... Ts>
struct overloaded : Ts... { using Ts::operator()...; };
template<class... Ts>
overloaded(Ts...) -> overloaded<Ts...>;

auto push_host(Host const& host, std::vector<uint8_t> &buffer) -> void
{
    auto const go = [&buffer](AddressType const ty, auto const thing) -> void {
        buffer.push_back(uint8_t(ty));
        buffer.push_back(thing.size());
        std::copy(thing.begin(), thing.end(), std::back_inserter(buffer));
    };

    std::visit(overloaded {
        [go](std::string_view const hostname) {
            go(AddressType::DomainName, hostname);
        },
        [go](boost::asio::ip::address const& address){
            if (address.is_v4()) {
                go(AddressType::IPv4, address.to_v4().to_bytes());
            } else if (address.is_v6()) {
                go(AddressType::IPv6, address.to_v6().to_bytes());
            } else {
                throw std::logic_error{"unexpected address type"};
            }
        }},
        host
    );
}

} // namespace detail

} // namespace socks5
