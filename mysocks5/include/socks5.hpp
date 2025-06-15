#pragma once

#include <boost/asio.hpp>
#include <boost/endian.hpp>

#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>

namespace socks5 {

struct SocksErrCategory : boost::system::error_category
{
    char const* name() const noexcept override;
    std::string message(int) const override;
};

extern SocksErrCategory const theSocksErrCategory;

enum class SocksErrc
{
    // Errors from the server
    Succeeded = 0,
    GeneralFailure = 1,
    NotAllowed = 2,
    NetworkUnreachable = 3,
    HostUnreachable = 4,
    ConnectionRefused = 5,
    TtlExpired = 6,
    CommandNotSupported = 7,
    AddressNotSupported = 8,
    // Errors from the client
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

struct NoCredential
{
};
struct UsernamePasswordCredential
{
    std::string_view username;
    std::string_view password;
};

using Auth = std::variant<NoCredential, UsernamePasswordCredential>;

namespace detail {

    template <class... Ts>
    struct overloaded : Ts...
    {
        using Ts::operator()...;
    };
    template <class... Ts>
    overloaded(Ts...) -> overloaded<Ts...>;

    auto make_socks_error(SocksErrc const err) -> boost::system::error_code;

    inline auto push_buffer(std::vector<std::uint8_t>& buffer, auto const& thing) -> void
    {
        buffer.push_back(thing.size());
        buffer.insert(buffer.end(), thing.begin(), thing.end());
    }

    uint8_t const socks_version_tag = 5;
    uint8_t const auth_version_tag = 1;

    enum class AuthMethod
    {
        NoAuth = 0,
        Gssapi = 1,
        UsernamePassword = 2,
        NoAcceptableMethods = 255,
    };

    enum class Command
    {
        Connect = 1,
        Bind = 2,
        UdpAssociate = 3,
    };

    enum class AddressType
    {
        IPv4 = 1,
        DomainName = 3,
        IPv6 = 4,
    };

    /// @brief Encode the given host into the end of the buffer
    /// @param host host to encode
    /// @param buffer target to push bytes onto
    /// @return true for success and false for failure
    auto push_host(Host const& host, std::vector<uint8_t>& buffer) -> void;

    template <typename AsyncStream>
    struct SocksImplementation
    {
        AsyncStream& socket_;
        Host const host_;
        boost::endian::big_uint16_t const port_;
        Auth const auth_;

        /// buffer used to back async read/write operations
        std::vector<uint8_t> buffer_;

        // Representations of states in the protocol
        struct Start
        {
        };
        struct HelloRecvd
        {
            static const std::size_t READ = 2; // version, method
        };
        struct AuthRecvd
        {
            static const std::size_t READ = 2; // subversion, status
        };
        struct ReplyRecvd
        {
            static const std::size_t READ = 4; // version, reply, reserved, address-tag
        };
        struct FinishIpv4
        {
            static const std::size_t READ = 6; // ipv4 + port = 6 bytes
        };
        struct FinishIpv6
        {
            static const std::size_t READ = 18; // ipv6 + port = 18 bytes
        };

        /// @brief State when the application needs to receive some bytes
        /// @tparam Next State to transistion to after read is successful
        template <typename Next>
        struct Sent
        {
        };

        /// @brief intermediate completion callback
        /// @tparam Self type of enclosing intermediate completion handler
        /// @tparam State protocol state tag type
        /// @param self enclosing intermediate completion handler
        /// @param state protocol state tag value
        /// @param error error code of read/write operation
        /// @param size bytes read or written
        /// @param
        template <typename Self, typename State = Start>
        auto operator()(
            Self& self,
            State state = {},
            boost::system::error_code const error = {},
            std::size_t = 0
        ) -> void
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

        /// @brief Write the buffer to the socket and then read N bytes back into the buffer
        /// @tparam Next state to resume after read
        /// @tparam N number of bytes to read
        /// @tparam Self type of enclosing intermediate completion handler
        /// @param self enclosing intermediate completion handler
        template <typename Next, typename Self>
        auto transact(Self& self) -> void
        {
            boost::asio::async_write(
                socket_,
                boost::asio::buffer(buffer_),
                [self = std::move(self)](boost::system::error_code const err, std::size_t const n) mutable {
                    self(Sent<Next>{}, err, n);
                }
            );
        }

        /// @brief Notify the caller of a failure and terminate the protocol
        /// @param self intermediate completion handler
        /// @param err error code to return to the caller
        auto failure(auto& self, SocksErrc const err) -> void
        {
            self.complete(make_socks_error(err), {});
        }

        /// @brief Read bytes needed by Next state from the socket and then proceed to Next state
        /// @tparam Self type of enclosing intermediate completion handler
        /// @tparam Next state to transition to after read
        /// @param self enclosing intermediate completion handler
        /// @param state protocol state tag
        template <typename Self, typename Next>
        auto step(Self& self, Sent<Next>) -> void
        {
            buffer_.resize(Next::READ);
            boost::asio::async_read(
                socket_,
                boost::asio::buffer(buffer_),
                [self = std::move(self)](boost::system::error_code const err, std::size_t n) mutable {
                    self(Next{}, err, n);
                }
            );
        }

        // Send hello and offer authentication methods
        template <typename Self>
        auto step(Self& self, Start) -> void
        {
            if (auto const* const host = std::get_if<std::string_view>(&host_))
            {
                if (host->size() >= 256)
                {
                    return failure(self, SocksErrc::DomainTooLong);
                }
            }
            if (auto const* const plain = std::get_if<UsernamePasswordCredential>(&auth_))
            {
                if (plain->username.size() >= 256)
                {
                    return failure(self, SocksErrc::UsernameTooLong);
                }
                if (plain->password.size() >= 256)
                {
                    return failure(self, SocksErrc::PasswordTooLong);
                }
            }

            buffer_ = {socks_version_tag, 1 /* number of methods */, static_cast<uint8_t>(method_wanted())};
            transact<HelloRecvd>(self);
        }

        // Send TCP connection request for the domain name and port
        template <typename Self>
        auto step(Self& self, HelloRecvd) -> void
        {
            if (socks_version_tag != buffer_[0])
            {
                return failure(self, SocksErrc::WrongVersion);
            }

            auto const wanted = method_wanted();
            auto const selected = static_cast<AuthMethod>(buffer_[1]);

            if (AuthMethod::NoAuth == wanted && wanted == selected)
            {
                send_connect(self);
            }
            else if (AuthMethod::UsernamePassword == wanted && wanted == selected)
            {
                send_usernamepassword(self);
            }
            else
            {
                failure(self, SocksErrc::NoAcceptableMethods);
            }
        }

        /// @brief Transmit the username and password to the server
        /// @tparam Self type of enclosing intermediate completion handler
        /// @param self enclosing intermediate completion handler
        template <typename Self>
        auto send_usernamepassword(Self& self) -> void
        {
            buffer_ = {
                auth_version_tag,
            };
            auto const [username, password] = std::get<1>(auth_);
            push_buffer(buffer_, username);
            push_buffer(buffer_, password);
            transact<AuthRecvd>(self);
        }

        template <typename Self>
        auto step(Self& self, AuthRecvd) -> void
        {
            if (auth_version_tag != buffer_[0])
            {
                return failure(self, SocksErrc::WrongVersion);
            }

            // STATUS zero is success, non-zero is failure
            if (0 != buffer_[1])
            {
                return failure(self, SocksErrc::AuthenticationFailed);
            }

            send_connect(self);
        }

        template <typename Self>
        auto send_connect(Self& self) -> void
        {
            buffer_ = {
                socks_version_tag,
                static_cast<uint8_t>(Command::Connect),
                0 /* reserved */,
            };
            push_host(host_, buffer_);
            buffer_.insert(buffer_.end(), port_.data(), port_.data() + 2);

            transact<ReplyRecvd>(self);
        }

        // Waiting on the remaining variable-sized address portion of the response
        template <typename Self>
        auto step(Self& self, ReplyRecvd) -> void
        {
            if (socks_version_tag != buffer_[0])
            {
                return failure(self, SocksErrc::WrongVersion);
            }
            auto const reply = static_cast<SocksErrc>(buffer_[1]);
            if (SocksErrc::Succeeded != reply)
            {
                return failure(self, reply);
            }

            switch (static_cast<AddressType>(buffer_[3]))
            {
            case AddressType::IPv4:
                return step(self, Sent<FinishIpv4>{});
            case AddressType::IPv6:
                return step(self, Sent<FinishIpv6>{});
            default:
                return failure(self, SocksErrc::UnsupportedEndpointAddress);
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

        auto method_wanted() const -> AuthMethod
        {
            return std::visit(
                overloaded{
                    [](NoCredential) { return AuthMethod::NoAuth; },
                    [](UsernamePasswordCredential) { return AuthMethod::UsernamePassword; },
                },
                auth_
            );
        }
    };

} // namespace detail

using Signature = void(boost::system::error_code, boost::asio::ip::tcp::endpoint);

/// @brief Asynchronous SOCKS5 connection request
/// @tparam AsyncStream Type of socket
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
)
{
    return boost::asio::async_compose<CompletionToken, Signature>(detail::SocksImplementation<AsyncStream>{socket, host, port, auth, {}}, token, socket);
}

} // namespace socks5
