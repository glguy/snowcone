#pragma once

#include <socks5.hpp>

#include <boost/asio.hpp>
#include <boost/asio/ssl.hpp>

#include <iosfwd>
#include <string>

/**
 * @brief Connect to TCP service
 *
 * @param os connection information output stream
 * @param stream unconnected socket
 * @param host remote hostname
 * @param port remote port number
 * @param bind_host optional local hostname
 * @param bind_port optional local port number
 * @return boost::asio::awaitable<void>
 */
auto tcp_connect(
    std::ostream& os,
    boost::asio::ip::tcp::socket& stream,
    std::string_view host, std::uint16_t port,
    std::string_view bind_host, std::uint16_t bind_port
) -> boost::asio::awaitable<void>;

/**
 * @brief Initiate TLS handshake over an established stream
 *
 * @param os connection information output stream
 * @param stream connected stream
 * @param verify optional hostname for certificate verification
 * @param sni optional hostname for SNI negotiation
 * @return coroutine handle
 */
template <typename T>
auto tls_connect(
    std::ostream& os,
    boost::asio::ssl::stream<T>& stream,
    std::string const& verify,
    std::string const& sni
    ) -> boost::asio::awaitable<void>;

extern template auto tls_connect(
    std::ostream& os,
    boost::asio::ssl::stream<boost::asio::ip::tcp::socket>& stream,
    std::string const& verify,
    std::string const& sni
    ) -> boost::asio::awaitable<void>;
