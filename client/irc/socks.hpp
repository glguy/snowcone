#pragma once

#include <boost/asio.hpp>
#include <boost/endian.hpp>

#include <array>
#include <cstdint>
#include <string>
#include <string_view>

namespace socks5
{

struct SocksErrCategory : boost::system::error_category
{
    const char* name() const noexcept override;
    std::string message(int) const override;
};

extern const SocksErrCategory theSocksErrCategory;

enum class SocksErrc {
    Succeeded = 0,
    GeneralFailure = 1,
    NotAllowed = 2,
    NetworkUnreachable = 3,
    HostUnreachable = 4,
    ConnectionRefused = 5,
    TtlExpired = 6,
    CommandNotSupported = 7,
    AddressNotSupported = 8,
};

namespace detail
{
using namespace std::placeholders;

uint8_t const version_tag = 5;
uint8_t const reserved = 0;

enum class AuthMethod {
    NoAuth = 0,
    Gssapi = 1,
    UsernamePassword = 2,
    NoAcceptableMethods = 255,
};

enum class Command {
    Connect = 1,
    Bind = 2,
    UdpAssociate = 3,
};

enum class AddressType {
    IPv4 = 1,
    DomainName = 3,
    IPv6 = 4,
};

struct SocksImplementation
{
    boost::asio::ip::tcp::socket& socket_;
    std::string_view const host_;
    boost::endian::big_uint16_t const port_;

    /// buffer used to back async read/write operations
    std::vector<uint8_t> buffer_;

    // Intermediate states used to dispatch to different operator() implementations
    struct RecvReply{};
    struct RecvHello{};
    struct SendConnect{};
    struct RecvAddress{};
    struct Finish{};

    // In the case of error codes, abort the process. Otherwise proceed
    // without the error code. This allows all the read/write error handling
    // to be factored out into one place.
    template <typename Self, typename... Ts>
    void operator()(Self& self, boost::system::error_code const error, Ts&&... t)
    {
        if (error)
        {
            self.complete(error);
        }
        else
        {
            (*this)(self, std::forward<Ts>(t)...);
        }
    }

    // START: Send hello and offer authentication methods
    template <typename Self>
    void operator()(Self& self)
    {
        buffer_ = {version_tag, 1 /* number of methods */, uint8_t(AuthMethod::NoAuth)};
        boost::asio::async_write(socket_, boost::asio::buffer(buffer_),
            std::bind(std::move(self), _1, _2, RecvHello{}));
    }

    // Waiting for server to choose authentication method
    template <typename Self>
    void operator()(
        Self& self,
        std::size_t,
        RecvHello
    ) {
        buffer_.resize(2); // version, method
        boost::asio::async_read(socket_, boost::asio::buffer(buffer_),
            std::bind(std::move(self), _1, _2, SendConnect{}));
    }

    // Send TCP connection request for the domain name and port
    template <typename Self>
    void operator()(
        Self& self,
        std::size_t,
        SendConnect
    ) {
        if (version_tag != buffer_[0])
        {
            self.complete(boost::system::errc::make_error_code(boost::system::errc::not_supported));
            return;
        }
        if (AuthMethod::NoAuth != static_cast<AuthMethod>(buffer_[1])) {
            self.complete(boost::system::errc::make_error_code(boost::system::errc::not_supported));
            return;
        }

        buffer_ = {
            version_tag,
            uint8_t(Command::Connect),
            reserved,
            uint8_t(AddressType::DomainName),
            uint8_t(host_.size())
        };
        std::array<boost::asio::const_buffer, 3> buffers {
            boost::asio::buffer(buffer_),
            boost::asio::buffer(host_),
            boost::asio::buffer(&port_, sizeof port_)
        };
        boost::asio::async_write(socket_, buffers,
            std::bind(std::move(self), _1, _2, RecvReply{}));
    }

    // Wait for response to the connection request
    template <typename Self>
    void operator()(
        Self& self,
        std::size_t,
        RecvReply
    ) {
        buffer_.resize(5); // version, reply, reserved, address-tag, first address byte
        boost::asio::async_read(socket_, boost::asio::buffer(buffer_),
            std::bind(std::move(self), _1, _2, RecvAddress{}));
    }

    // Waiting on the remaining variable-sized address portion of the response
    template <typename Self>
    void operator()(
        Self& self,
        std::size_t,
        RecvAddress
    ) {
        if (version_tag != buffer_[0])
        {
            self.complete(boost::system::errc::make_error_code(boost::system::errc::not_supported));
            return;
        }
        auto const reply = static_cast<SocksErrc>(buffer_[1]);
        if (SocksErrc::Succeeded != reply)
        {
            self.complete(boost::system::error_code{int(reply), theSocksErrCategory});
            return;
        }

        std::size_t n;
        switch (static_cast<AddressType>(buffer_[3])) {
            case AddressType::IPv4:
                n = 5; // ipv4 + port
                break;
            case AddressType::DomainName:
                n = size_t(buffer_[4]) + 2; // domain name + port
                break;
            case AddressType::IPv6:
                n = 17; // ipv6 + port
                break;
            default:
                self.complete(boost::system::errc::make_error_code(boost::system::errc::not_supported));
                return;
        }

        buffer_.resize(n);
        boost::asio::async_read(socket_, boost::asio::buffer(buffer_),
            std::bind(std::move(self), _1, _2, Finish{}));
    }

    // Protocol complete!
    template <typename Self>
    void operator()(
        Self& self,
        std::size_t,
        Finish
    ) {
        self.complete({});
    }
};

} // namespace detail

/// @brief Asynchronous SOCKS5 connection request
/// @tparam CompletionToken Completion token type
/// @param socket Established connection to SOCKS5 server
/// @param host Target hostname
/// @param port Target port number
/// @param token Completion token
/// @return Behavior determined by completion token type
template <boost::asio::completion_token_for<void(boost::system::error_code)> CompletionToken>
auto async_connect(
    boost::asio::ip::tcp::socket& socket,
    std::string_view const host,
    uint16_t const port,
    CompletionToken&& token
) {
    return boost::asio::async_compose
        <CompletionToken, void(boost::system::error_code), detail::SocksImplementation>
        ({socket, host, port}, token, socket);
}

} // namespace socks5
