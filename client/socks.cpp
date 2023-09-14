#include "socks.hpp"

#include <boost/asio.hpp>

#include <array>
#include <iterator>
#include <vector>

namespace {

uint8_t const version_tag = 5;
uint8_t const reserved = 0;

enum Reply {
    Succeeded = 0, // succeeded
    GeneralFailure = 1, // general SOCKS server failure
    NotAllowed = 2, // connection not allowed by ruleset
    NetworkUnreachable = 3, // Network unreachable
    HostUnreachable = 4, // Host unreachable
    ConnectionRefused = 5, // Connection refused
    TtlExpired = 6, // TTL expired
    CommandNotSupported = 7, // Command not supported
    AddressNotSupported = 8, // Address type not supported
};

enum AuthMethod {
    NoAuth = 0,
    Gssapi = 1,
    UsernamePassword = 2,
    NoAcceptableMethods = 255,
};

enum Command {
    Connect = 1,
    Bind = 2,
    UdpAssociate = 3,
};

} // namespace

auto socks_connect(
    boost::asio::ip::tcp::socket& socket,
    std::string_view host,
    uint16_t port
) -> boost::asio::awaitable<void>
{
    if (host.size() > 255) {
        throw std::runtime_error{"hostname too big for socks"};
    }

    // Send the client hello
    {
        uint8_t buffer[] {version_tag, 1, AuthMethod::NoAuth};
        co_await boost::asio::async_write(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);
    }

    // Receive the server hello
    {
        uint8_t buffer[2]; // version, method
        co_await boost::asio::async_read(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);
        if (buffer[0] != version_tag || buffer[1] != AuthMethod::NoAuth) {
            throw std::runtime_error {"bad socks hello"};
        }
    }

    // Build the connect request
    {
        uint8_t request[] {version_tag, Command::Connect, reserved, 3, uint8_t(host.size())};
        uint8_t port_buffer[] {uint8_t(port>>8), uint8_t(port)};
        std::array<boost::asio::const_buffer, 3> const buffers {
            boost::asio::buffer(request),
            boost::asio::buffer(host),
            boost::asio::buffer(port_buffer),
        };
        co_await boost::asio::async_write(socket, buffers, boost::asio::use_awaitable);
    }

    // Receive the connect reply
    uint8_t reply[5]; // version, reply, reserved, address-tag, first address byte
    co_await boost::asio::async_read(socket, boost::asio::buffer(reply), boost::asio::use_awaitable);
    if (reply[0] != version_tag || reply[1] != Reply::Succeeded)
    {
        throw std::runtime_error{"socks request unsuccessful"};
    }

    // Ignore the returned address (first byte already in buffer)
    switch (reply[3]) {
        case 1: {
            uint8_t buffer[5]; // ipv4 + port
            co_await boost::asio::async_read(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);
            break;
        }
        case 3: {
            std::vector<uint8_t> buffer(size_t(reply[4]) + 2); // domain name + port
            co_await boost::asio::async_read(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);
            break;
        }
        case 4: {
            uint8_t buffer[17]; // ipv6 + port
            co_await boost::asio::async_read(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);
            break;
        }
        default:
            throw std::runtime_error {"bad socks confirmation address type"};
    }
}
