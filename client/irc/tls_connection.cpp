#include "tls_connection.hpp"

#include "socks.hpp"

#include <iomanip>
#include <sstream>

tls_irc_connection::tls_irc_connection(
    boost::asio::io_context &io_context,
    boost::asio::ssl::context &ssl_context,
    lua_State *const L)
: irc_connection{io_context, L}, socket_{io_context, ssl_context}
{
}

auto tls_irc_connection::write_awaitable() -> boost::asio::awaitable<std::size_t>
{
    return boost::asio::async_write(socket_, write_buffers, boost::asio::use_awaitable);
}

auto tls_irc_connection::read_awaitable(
    boost::asio::mutable_buffers_1 const& buffers
) -> boost::asio::awaitable<std::size_t>
{
    return socket_.async_read_some(buffers, boost::asio::use_awaitable);
}

auto tls_irc_connection::connect(
    boost::asio::ip::tcp::resolver::results_type const& endpoints,
    std::string const& verify,
    std::string_view socks_host,
    uint16_t socks_port
) -> boost::asio::awaitable<std::string>
{
    // TCP connection
    co_await irc_connection::basic_connect(socket_.next_layer(), endpoints, socks_host, socks_port);

    // TLS connection
    if (not verify.empty())
    {
        socket_.set_verify_mode(boost::asio::ssl::verify_peer);
        socket_.set_verify_callback(boost::asio::ssl::host_name_verification(verify));
    }
    co_await socket_.async_handshake(socket_.client, boost::asio::use_awaitable);

    // Server fingerprint computation
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int md_len = 0; // if the digest somehow fails, use 0
    auto const cert = SSL_get0_peer_certificate(socket_.native_handle());
    X509_pubkey_digest(cert, EVP_sha256(), md, &md_len);

    // Server fingerprint representation
    std::stringstream fingerprint;
    fingerprint << std::hex << std::setfill('0');
    for (unsigned i = 0; i < md_len; i++) {
        fingerprint << std::setw(2) << int{md[i]};
    }

    co_return fingerprint.str();
}

auto tls_irc_connection::close() -> boost::system::error_code
{
    boost::system::error_code error;
    return socket_.lowest_layer().close(error);
}
