#include "net.hpp"

#include <boost/io/ios_state.hpp>

#include <iomanip>

auto TcpStream::async_read_some_(mutable_buffers buffers, boost::asio::any_completion_handler<void(boost::system::error_code, std::size_t)> handler) -> void
{
    stream_.async_read_some(buffers, std::move(handler));
}

auto TcpStream::async_write_some_(const_buffers buffers, boost::asio::any_completion_handler<void(boost::system::error_code, std::size_t)> handler) -> void
{
    stream_.async_write_some(buffers, std::move(handler));
}

auto TcpConnectParams::connect(std::ostream &os, stream_type &stream) -> boost::asio::awaitable<void>
{
    auto resolver = boost::asio::ip::tcp::resolver{stream.get_executor()};

    if (not bind_host.empty() || bind_port != 0)
    {
        auto const entries =
            co_await resolver.async_resolve(bind_host, std::to_string(bind_port), boost::asio::use_awaitable);
        auto const &entry = *entries.begin();

        stream.open(entry.endpoint().protocol());
        stream.bind(entry);
    }

    auto const entries =
        co_await resolver.async_resolve(host, std::to_string(port), boost::asio::use_awaitable);

    os << "tcp=" << co_await boost::asio::async_connect(stream, entries, boost::asio::use_awaitable);
    stream.set_option(boost::asio::ip::tcp::no_delay(true));
}

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
