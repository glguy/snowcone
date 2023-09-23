#include "tls_connection.hpp"

#include "socks.hpp"

#include <iomanip>
#include <sstream>

namespace {

auto peer_fingerprint(SSL const* const ssl) -> std::string
{
    // Server fingerprint computation
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int md_len = 0; // if the digest somehow fails, use 0
    auto const cert = SSL_get0_peer_certificate(ssl);
    X509_pubkey_digest(cert, EVP_sha256(), md, &md_len);

    // Server fingerprint representation
    std::stringstream fingerprint;
    fingerprint << std::hex << std::setfill('0');
    for (unsigned i = 0; i < md_len; i++) {
        fingerprint << std::setw(2) << int{md[i]};
    }

    return fingerprint.str();
}

} // namespace

tls_irc_connection::tls_irc_connection(
    boost::asio::io_context &io_context,
    boost::asio::ssl::context &ssl_context,
    lua_State *const L)
: irc_connection{io_context, L}, socket_{io_context, ssl_context}
{
}

auto tls_irc_connection::async_write() -> void
{
    irc_connection::async_write_impl(socket_);
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
    std::string_view const socks_host,
    uint16_t const socks_port
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
    co_return peer_fingerprint(socket_.native_handle());
}

auto tls_irc_connection::close() -> boost::system::error_code
{
    boost::system::error_code error;
    return socket_.lowest_layer().close(error);
}

auto build_ssl_context(
    std::string const& client_cert,
    std::string const& client_key,
    std::string const& client_key_password
) -> boost::asio::ssl::context
{
    boost::asio::ssl::context ssl_context{boost::asio::ssl::context::method::tls_client};
    ssl_context.set_default_verify_paths();
    if (not client_key_password.empty())
    {
        ssl_context.set_password_callback(
            [client_key_password](
                std::size_t const max_size,
                boost::asio::ssl::context::password_purpose const purpose)
            {
                return client_key_password.size() <= max_size ? client_key_password : "";
            });
    }
    if (not client_cert.empty())
    {
        ssl_context.use_certificate_file(client_cert, boost::asio::ssl::context::file_format::pem);
    }
    if (not client_key.empty())
    {
        ssl_context.use_private_key_file(client_key, boost::asio::ssl::context::file_format::pem);
    }
    return ssl_context;
}
