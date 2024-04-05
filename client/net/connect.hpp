#pragma once

#include <socks5.hpp>

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <iosfwd>
#include <string>

template <typename T>
concept Connectable = requires(T a, std::ostream& os, typename T::stream_type &stream) {
    // Check for the presence of a typedef named stream_type
    typename T::stream_type;

    // Check for the method with the correct signature
    {
        a.connect(os, stream)
    } -> std::same_as<boost::asio::awaitable<void>>;
};

struct TcpConnectParams
{
    using stream_type = boost::asio::ip::tcp::socket;

    /// @brief remote endpoint hostname
    std::string host;

    /// @brief remote endpoint port
    std::uint16_t port;

    /// @brief optional local endpoint hostname
    std::string bind_host;

    /// @brief optional local endpoint port
    std::uint16_t bind_port;

    /// @brief Connect to TCP endpoint
    auto connect(std::ostream& os, stream_type &stream) -> boost::asio::awaitable<void>;
};

template <Connectable T>
struct SocksConnectParams
{
    using stream_type = typename T::stream_type;

    /// @brief hostname used in socks5 CONNECT command
    std::string host;

    /// @brief port used in socks5 CONNECT command
    std::uint16_t port;

    /// @brief authentication mechanism used in SOCKS5 protocol
    socks5::Auth auth;

    /// @brief Underlying connection parameters
    T base;

    /// @brief Connect underlying stream and then negotiate SOCKS5 CONNECT
    auto connect(std::ostream& os, stream_type &stream) -> boost::asio::awaitable<void>;
};

template <Connectable T>
struct TlsConnectParams
{
    using stream_type = boost::asio::ssl::stream<typename T::stream_type>;

    /// @brief Hostname to verify on remote certificate (if not empty)
    std::string verify;

    /// @brief Hostname to use with SNI to request specific certificate (if not empty)
    std::string sni;

    /// @brief Underlying connection parameters
    T base;

    /// @brief Connect underlying stream and then initiate TLS session
    auto connect(std::ostream& os, stream_type &stream) -> boost::asio::awaitable<void>;
};

extern template class SocksConnectParams<TcpConnectParams>;
extern template class TlsConnectParams<TcpConnectParams>;
extern template class TlsConnectParams<SocksConnectParams<TcpConnectParams>>;

static_assert(Connectable<TcpConnectParams>);
static_assert(Connectable<SocksConnectParams<TcpConnectParams>>);
static_assert(Connectable<TlsConnectParams<SocksConnectParams<TcpConnectParams>>>);
static_assert(Connectable<TlsConnectParams<TcpConnectParams>>);
