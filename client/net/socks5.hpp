#pragma once

#include <boost/asio.hpp>
#include <boost/endian.hpp>

#include <cstdint>
#include <cstring>
#include <ranges>
#include <stdexcept>
#include <string>
#include <variant>

#include "proxyauth.hpp"

namespace socks5 {

/// Errors of a SOCKS5 connect: the server's reply codes and the client's
/// own protocol checks (SocksErrc)
struct SocksErrCategory : boost::system::error_category
{
    /// "socks5"
    char const* name() const noexcept override;
    /// A description of the SocksErrc value; "(unrecognized error)" for any
    /// other value
    std::string message(int) const override;
};

extern SocksErrCategory const theSocksErrCategory;

enum class SocksErrc : int
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

/// The error_code for a SocksErrc, in theSocksErrCategory
auto make_error_code(SocksErrc) -> boost::system::error_code;

/// Either a hostname or an address. Hostnames are resolved locally on the proxy server
using Host = std::variant<std::string, boost::asio::ip::address>;

namespace detail {
    template <typename T>
    concept RecvState = requires {
        {  T::READ } -> std::convertible_to<std::size_t>;
    };

    /// A visitor made of several lambdas, one per alternative
    template <class... Ts>
    struct overloaded : Ts...
    {
        using Ts::operator()...;
    };
    template <class... Ts>
    overloaded(Ts...) -> overloaded<Ts...>;

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

    template <typename AsyncStream>
    struct SocksImplementation
    {
        /// @brief Socket to SOCKS server
        AsyncStream& socket_;

        /// @brief Target hostname
        Host const host_;

        /// @brief Target port number
        boost::endian::big_uint16_t const port_;

        /// @brief SOCKS server authentication parameters
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
        template <RecvState Next>
        struct Sent
        {
        };

        /// @brief intermediate completion callback: completes with the error
        /// if the last read or write failed, else runs the state's step
        /// @tparam Self type of enclosing intermediate completion handler
        /// @tparam State protocol state tag type
        /// @param self enclosing intermediate completion handler
        /// @param state protocol state tag value
        /// @param error error code of read/write operation
        /// @param size bytes read or written (unused)
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

        /// @brief Write the buffer to the socket and then read Next::READ
        /// bytes back into the buffer
        /// @tparam Next state to resume after read
        /// @tparam Self type of enclosing intermediate completion handler
        /// @param self enclosing intermediate completion handler
        template <RecvState Next, typename Self>
        auto transact(Self& self) -> void
        {
            // buffer_ lives in self: take the view before self is moved, since
            // the order arguments are evaluated in is unspecified
            auto const buffer = boost::asio::buffer(buffer_);
            boost::asio::async_write(
                socket_,
                buffer,
                std::bind_front(std::move(self), Sent<Next>{})
            );
        }

        /// @brief Notify the caller of a failure and terminate the protocol
        /// @param self intermediate completion handler
        /// @param err error code to return to the caller
        static auto failure(auto& self, SocksErrc const err) -> void
        {
            self.complete(make_error_code(err), {});
        }

        /// @brief Append thing to the buffer after a one-byte length; the
        /// caller ensures it is under 256 bytes
        inline auto push_size_prefixed(std::ranges::sized_range auto const& thing) -> void
        requires true
        {
            using std::ranges::size;
            using std::ranges::begin;
            using std::ranges::end;

            buffer_.push_back(size(thing));
            buffer_.insert(end(buffer_), begin(thing), end(thing));
        }

        /// @brief Encode the target host (address type and address) at the
        /// end of the buffer. A hostname must already be checked to be
        /// under 256 bytes.
        /// @throws std::logic_error for an address neither v4 nor v6
        auto push_host() -> void
        {
            std::visit(overloaded {
                [this](std::string const& hostname) {
                    buffer_.push_back(static_cast<uint8_t>(AddressType::DomainName));
                    push_size_prefixed(hostname);
                },
                // Addresses are fixed-length, so they have no length prefix
                [this](boost::asio::ip::address const& address) {
                    if (address.is_v4())
                    {
                        auto const bytes = address.to_v4().to_bytes();
                        buffer_.push_back(static_cast<uint8_t>(AddressType::IPv4));
                        buffer_.insert(buffer_.end(), bytes.begin(), bytes.end());
                    }
                    else if (address.is_v6())
                    {
                        auto const bytes = address.to_v6().to_bytes();
                        buffer_.push_back(static_cast<uint8_t>(AddressType::IPv6));
                        buffer_.insert(buffer_.end(), bytes.begin(), bytes.end());
                    }
                    else
                    {
                        throw std::logic_error{"unexpected address type"};
                    }
                }},
                host_);
        }

        /// @brief Push the configured port number into the send buffer
        auto push_port() -> void
        {
            buffer_.insert(buffer_.end(), port_.data(), port_.data() + 2);
        }

        /// @brief Read bytes needed by Next state from the socket and then proceed to Next state
        /// @tparam Self type of enclosing intermediate completion handler
        /// @tparam Next state to transition to after read
        /// @param self enclosing intermediate completion handler
        template <typename Self, RecvState Next>
        auto step(Self& self, Sent<Next>) -> void
        {
            buffer_.resize(Next::READ);
            auto const buffer = boost::asio::buffer(buffer_); // before self is moved
            boost::asio::async_read(
                socket_,
                buffer,
                std::bind_front(std::move(self), Next{})
            );
        }

        /// Check the lengths that must fit in a byte, then send hello
        /// offering the one authentication method the credentials call for
        template <typename Self>
        auto step(Self& self, Start) -> void
        {
            if (auto const* const host = std::get_if<std::string>(&host_))
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

            // +----+----------+----------+
            // |VER | NMETHODS | METHODS  |
            // +----+----------+----------+
            // | 1  |    1     | 1 to 255 |
            // +----+----------+----------+

            buffer_ = {socks_version_tag, 1 /* number of methods */, static_cast<uint8_t>(method_wanted())};
            transact<HelloRecvd>(self);
        }

        /// Check the server's choice of method, then authenticate or send
        /// the connect request
        template <typename Self>
        auto step(Self& self, HelloRecvd) -> void
        {
            // +----+--------+
            // |VER | METHOD |
            // +----+--------+
            // | 1  |   1    |
            // +----+--------+

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
            // +----+------+----------+------+----------+
            // |VER | ULEN |  UNAME   | PLEN |  PASSWD  |
            // +----+------+----------+------+----------+
            // | 1  |  1   | 1 to 255 |  1   | 1 to 255 |
            // +----+------+----------+------+----------+

            buffer_ = {
                auth_version_tag,
            };
            auto const& [username, password] = std::get<UsernamePasswordCredential>(auth_);
            push_size_prefixed(username);
            push_size_prefixed(password);
            transact<AuthRecvd>(self);
        }

        /// Check the authentication status, then send the connect request
        template <typename Self>
        auto step(Self& self, AuthRecvd) -> void
        {
            // +----+--------+
            // |VER | STATUS |
            // +----+--------+
            // | 1  |   1    |
            // +----+--------+

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

        /// @brief Send the CONNECT request for the target host and port
        template <typename Self>
        auto send_connect(Self& self) -> void
        {
            // +----+-----+-------+------+----------+----------+
            // |VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
            // +----+-----+-------+------+----------+----------+
            // | 1  |  1  | X'00' |  1   | Variable |    2     |
            // +----+-----+-------+------+----------+----------+

            buffer_ = {
                socks_version_tag,
                static_cast<uint8_t>(Command::Connect),
                0 /* reserved */,
            };
            push_host();
            push_port();
            transact<ReplyRecvd>(self);
        }

        /// Check the reply's version, code and reserved byte, then read the
        /// bound address it carries. A domain-name address is rejected.
        template <typename Self>
        auto step(Self& self, ReplyRecvd) -> void
        {
            // +----+-----+-------+------+----------+----------+
            // |VER | REP |  RSV  | ATYP | BND.ADDR | BND.PORT |
            // +----+-----+-------+------+----------+----------+
            // | 1  |  1  | X'00' |  1   | Variable |    2     |
            // +----+-----+-------+------+----------+----------+

            if (socks_version_tag != buffer_[0])
            {
                return failure(self, SocksErrc::WrongVersion);
            }
            auto const reply = static_cast<SocksErrc>(buffer_[1]);
            if (SocksErrc::Succeeded != reply)
            {
                return failure(self, reply);
            }

            if (0 != buffer_[2]) {
                return failure(self, SocksErrc::GeneralFailure);
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

        /// Protocol complete! Return the bound address the proxy reported
        template <typename Self>
        void step(Self& self, FinishIpv4)
        {
            boost::asio::ip::address_v4::bytes_type bytes;
            boost::endian::big_uint16_t port;
            std::memcpy(bytes.data(), &buffer_[0], 4);
            std::memcpy(port.data(), &buffer_[4], 2);
            self.complete({}, {boost::asio::ip::address_v4{bytes}, port});
        }

        /// Protocol complete! Return the bound address the proxy reported
        template <typename Self>
        void step(Self& self, FinishIpv6)
        {
            boost::asio::ip::address_v6::bytes_type bytes;
            boost::endian::big_uint16_t port;
            std::memcpy(bytes.data(), &buffer_[0], 16);
            std::memcpy(port.data(), &buffer_[16], 2);
            self.complete({}, {boost::asio::ip::address_v6{bytes}, port});
        }

        /// The method the credentials call for: none, or username/password
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
/// @tparam CompletionToken Token accepting: error_code, and the tcp::endpoint
/// the proxy reported as bound for the connection
/// @param socket Established connection to SOCKS5 server
/// @param host Connection target host
/// @param port Connection target port
/// @param auth Credentials, or NoCredential; a username or password of 256
/// bytes or more fails with UsernameTooLong or PasswordTooLong
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
