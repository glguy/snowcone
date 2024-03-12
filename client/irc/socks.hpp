#pragma once

#include <boost/asio.hpp>
#include <boost/endian.hpp>

#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>
#include <variant>
#include <stdexcept>

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
    // protocol sent reply codes are always a single byte
    WrongVersion = 256,
    NoAcceptableMethods,
    AuthenticationFailed,
    UnsupportedEndpointAddress,
    DomainTooLong,
    UsernameTooLong,
    PasswordTooLong,
};

/// Either a hostname or an address. Hostnames are resolved locally on the proxy server
using Host = std::variant<std::string_view, boost::asio::ip::address>;

struct NoCredential {};
struct UsernamePasswordCredential {
    std::string_view username;
    std::string_view password;
};

using Auth = std::variant<NoCredential, UsernamePasswordCredential>;

namespace detail
{
auto make_socks_error(SocksErrc const err) -> boost::system::error_code;

inline auto push_buffer(std::vector<std::uint8_t>&buffer, auto const& thing) -> void
{
    buffer.push_back(thing.size());
    std::copy(thing.begin(), thing.end(), std::back_inserter(buffer));
}

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

/// @brief Encode the given host into the end of the buffer
/// @param host host to encode
/// @param buffer target to push bytes onto
/// @return true for success and false for failure
auto push_host(Host const& host, std::vector<uint8_t> &buffer) -> void;

template<typename AsyncStream>
struct SocksImplementation
{
    AsyncStream& socket_;
    Host const host_;
    boost::endian::big_uint16_t const port_;
    Auth auth_;

    /// buffer used to back async read/write operations
    std::vector<uint8_t> buffer_;

    // Representations of states in the protocol
    struct Start{};
    struct HelloSent{};
    struct HelloRecvd{};
    struct AuthSent{};
    struct AuthRecvd{};
    struct ConnectSent{};
    struct ReplyRecvd{};
    struct FinishIpv4{};
    struct FinishIpv6{};

    // In the case of error codes, abort the process.
    // Disregard the bytes_transferred.
    // Dispatch to the handler function for the target state
    template <typename Self, typename State = Start>
    void operator()(Self& self, State state = {}, boost::system::error_code const error = {}, std::size_t = {})
    {
        if (error)
        {
            self.complete(error, {});
        }
        else
        {
            step(self, state);
        }
    }

    // Send hello and offer authentication methods
    template <typename Self>
    void step(Self& self, Start)
    {
        if (auto const* const host = std::get_if<std::string_view>(&host_))
        {
            if (host->size() >= 256)
            {
                self.complete(make_socks_error(SocksErrc::DomainTooLong), {});
                return;
            }
        }
        if (auto const* const plain = std::get_if<UsernamePasswordCredential>(&auth_))
        {
            if (plain->username.size() >= 256)
            {
                self.complete(make_socks_error(SocksErrc::UsernameTooLong), {});
                return;
            }
            if (plain->password.size() >= 256)
            {
                self.complete(make_socks_error(SocksErrc::PasswordTooLong), {});
                return;
            }
        }

        AuthMethod method = auth_.index() == 0 ? AuthMethod::NoAuth : AuthMethod::UsernamePassword;
        buffer_ = {version_tag, 1 /* number of methods */, uint8_t(method)};
        boost::asio::async_write(socket_, boost::asio::buffer(buffer_),
            std::bind_front(std::move(self), HelloSent{}));
    }

    // Waiting for server to choose authentication method
    template <typename Self>
    void step(Self& self, HelloSent)
    {
        buffer_.resize(2); // version, method
        boost::asio::async_read(socket_, boost::asio::buffer(buffer_),
            std::bind_front(std::move(self), HelloRecvd{}));
    }

    // Send TCP connection request for the domain name and port
    template <typename Self>
    void step(Self& self, HelloRecvd)
    {
        if (version_tag != buffer_[0])
        {
            self.complete(make_socks_error(SocksErrc::WrongVersion), {});
            return;
        }

        AuthMethod method = static_cast<AuthMethod>(buffer_[1]);
        if (AuthMethod::NoAuth == method && auth_.index() == 0)
        {
            send_connect(self);
        }
        else if (AuthMethod::UsernamePassword == method && auth_.index() == 1)
        {
            send_usernamepassword(self);
        }
        else
        {
            self.complete(make_socks_error(SocksErrc::NoAcceptableMethods), {});
        }
    }

    template <typename Self>
    void send_usernamepassword(Self& self)
    {
        buffer_ = {
            1, // version
        };
        push_buffer(buffer_, std::get<1>(auth_).username);
        push_buffer(buffer_, std::get<1>(auth_).password);

        boost::asio::async_write(socket_, boost::asio::buffer(buffer_),
            std::bind_front(std::move(self), AuthSent{}));
    }

    template <typename Self>
    void step(Self& self, AuthSent)
    {
        buffer_.resize(2); // version, status
        boost::asio::async_read(socket_, boost::asio::buffer(buffer_),
            std::bind_front(std::move(self), AuthRecvd{}));
    }

    template <typename Self>
    void step(Self& self, AuthRecvd)
    {
        if (1 != buffer_[0])
        {
            self.complete(make_socks_error(SocksErrc::WrongVersion), {});
            return;
        }
        if (0 != buffer_[1])
        {
            self.complete(make_socks_error(SocksErrc::AuthenticationFailed), {});
            return;
        }

        send_connect(self);
    }

    template <typename Self>
    void send_connect(Self& self)
    {
        buffer_ = {
            version_tag,
            uint8_t(Command::Connect),
            reserved,
        };

        push_host(host_, buffer_);
        std::copy_n(port_.data(), 2, std::back_inserter(buffer_));

        boost::asio::async_write(socket_, boost::asio::buffer(buffer_),
            std::bind_front(std::move(self), ConnectSent{}));
    }

    // Wait for response to the connection request
    template <typename Self>
    void step(Self& self, ConnectSent)
    {
        buffer_.resize(4); // version, reply, reserved, address-tag
        boost::asio::async_read(socket_, boost::asio::buffer(buffer_),
            std::bind_front(std::move(self), ReplyRecvd{}));
    }

    // Waiting on the remaining variable-sized address portion of the response
    template <typename Self>
    void step(Self& self, ReplyRecvd)
    {
        if (version_tag != buffer_[0])
        {
            self.complete(make_socks_error(SocksErrc::WrongVersion), {});
            return;
        }
        auto const reply = static_cast<SocksErrc>(buffer_[1]);
        if (SocksErrc::Succeeded != reply)
        {
            self.complete(make_socks_error(reply), {});
            return;
        }

        switch (static_cast<AddressType>(buffer_[3])) {
            case AddressType::IPv4:
                // ipv4 + port = 6 bytes
                buffer_.resize(6);
                boost::asio::async_read(socket_, boost::asio::buffer(buffer_),
                    std::bind_front(std::move(self), FinishIpv4{}));
                return;
            case AddressType::IPv6:
                // ipv6 + port = 18 bytes
                buffer_.resize(18);
                boost::asio::async_read(socket_, boost::asio::buffer(buffer_),
                    std::bind_front(std::move(self), FinishIpv6{}));
                return;
            default:
                self.complete(make_socks_error(SocksErrc::UnsupportedEndpointAddress), {});
                return;
        }
    }

    // Protocol complete! Return the client's remote endpoint
    template <typename Self>
    void step(Self& self, FinishIpv4)
    {
        boost::asio::ip::address_v4::bytes_type bytes;
        boost::endian::big_uint16_t port;
        std::memcpy(bytes.data(), &buffer_[0], 4);
        std::memcpy(port.data(), &buffer_[4], 2);
        self.complete({}, {boost::asio::ip::make_address_v4(bytes), port});
    }

    // Protocol complete! Return the client's remote endpoint
    template <typename Self>
    void step(Self& self, FinishIpv6)
    {
        boost::asio::ip::address_v6::bytes_type bytes;
        boost::endian::big_uint16_t port;
        std::memcpy(bytes.data(), &buffer_[0], 16);
        std::memcpy(port.data(), &buffer_[16], 2);
        self.complete({}, {boost::asio::ip::make_address_v6(bytes), port});
    }
};

} // namespace detail

using Signature = void(boost::system::error_code, boost::asio::ip::tcp::endpoint);

/// @brief Asynchronous SOCKS5 connection request
/// @tparam CompletionToken Token accepting: error_code, address, port
/// @param socket Established connection to SOCKS5 server
/// @param host Connection target host
/// @param port Connection target port
/// @param token Completion token
/// @return Behavior determined by completion token type
template <
    typename AsyncStream,
    boost::asio::completion_token_for<Signature> CompletionToken>
auto async_connect(
    AsyncStream& socket,
    Host const host,
    uint16_t const port,
    Auth const auth,
    CompletionToken&& token
) {
    return boost::asio::async_compose
        <CompletionToken, Signature, detail::SocksImplementation<AsyncStream>>
        ({socket, host, port, auth}, token, socket);
}

} // namespace socks5
