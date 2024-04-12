#include "connect-impl.hpp"

#include <boost/asio.hpp>

auto peer_fingerprint(std::ostream &os, SSL const *const ssl) -> void
{
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int md_len = 0; // if the digest somehow fails, use 0
    auto const cert = SSL_get0_peer_certificate(ssl);
    X509_pubkey_digest(cert, EVP_sha256(), md, &md_len);

    boost::io::ios_flags_saver saver{os};

    // Server fingerprint representation
    os << std::hex << std::setfill('0');
    for (unsigned i = 0; i < md_len; i++)
    {
        os << std::setw(2) << int{md[i]};
    }
}

auto tcp_bind(
    boost::asio::ip::tcp::socket& stream,
    std::string_view host, std::uint16_t port
) -> boost::asio::awaitable<void>
{
    auto resolver = boost::asio::ip::tcp::resolver{stream.get_executor()};
    auto const entries =
        co_await resolver.async_resolve(host, std::to_string(port), boost::asio::use_awaitable);
    auto const &entry = *entries.begin();
    stream.open(entry.endpoint().protocol());
    stream.bind(entry);
}

auto tcp_connect(
    boost::asio::ip::tcp::socket& stream,
    std::string_view host, std::uint16_t port
) -> boost::asio::awaitable<void>
{
    auto resolver = boost::asio::ip::tcp::resolver{stream.get_executor()};
    auto const entries =
        co_await resolver.async_resolve(host, std::to_string(port), boost::asio::use_awaitable);

    co_await boost::asio::async_connect(stream, entries, boost::asio::use_awaitable);
    stream.set_option(boost::asio::ip::tcp::no_delay(true));
}

template auto tls_connect(
    boost::asio::ssl::stream<boost::asio::ip::tcp::socket>& stream,
    std::string const& verify,
    std::string const& sni
    ) -> boost::asio::awaitable<void>;
