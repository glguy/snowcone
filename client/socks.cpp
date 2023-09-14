#include "socks.hpp"

#include <boost/asio.hpp>

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

    std::vector<uint8_t> buffer;

    // Send the client hello
    buffer = {version_tag, 1, AuthMethod::NoAuth};
    co_await boost::asio::async_write(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);

    // Receive the server hello
    buffer.resize(2); // version, method
    co_await boost::asio::async_read(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);
    if (buffer[0] != version_tag || buffer[1] != AuthMethod::NoAuth) {
        throw std::runtime_error {"bad socks hello"};
    }

    // Build the connect request
    buffer = {version_tag, Command::Connect, reserved, 3, uint8_t(host.size())};
    std::copy(host.begin(), host.end(), std::back_inserter(buffer));
    
    // big-endian port number
    buffer.push_back(port >> 8);
    buffer.push_back(port);

    // Send the connect request
    co_await boost::asio::async_write(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);

    // Receive the connect reply
    buffer.resize(5); // version, reply, reserved, address-tag, first address byte
    co_await boost::asio::async_read(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);

    // Ignore the returned address (first byte already in buffer)
    switch (buffer[3]) {
        case 1:
            buffer.resize(3+2); // ipv4 + port
            co_await boost::asio::async_read(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);
            break;
        case 3:
            buffer.resize(size_t(buffer[4]) + 2); // domain name + port
            co_await boost::asio::async_read(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);
            break;
        case 4:
            buffer.resize(15+2); // ipv6 + port
            co_await boost::asio::async_read(socket, boost::asio::buffer(buffer), boost::asio::use_awaitable);
            break;
        default:
            throw std::runtime_error {"bad socks confirmation address type"};
    }

    if (buffer[0] != version_tag || buffer[1] != Reply::Succeeded)
    {
        throw std::runtime_error{"socks request unsuccessful"};
    }
}
