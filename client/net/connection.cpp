#include "connection.hpp"

#include <socks5.hpp>
#include <httpconnect.hpp>

#include <boost/io/ios_state.hpp>

#include <array>
#include <iomanip>
#include <vector>

connection::connection(boost::asio::io_context& io_context)
    : stream_{io_context}
    , resolver_{io_context}
{
}

auto connection::write(std::string_view const cmd) -> void
{
    if (not cmd.empty())
    {
        send_.insert(end(send_), begin(cmd), end(cmd));
        if (sending_.empty())
        {
            write_actual();
        }
    }
}

auto connection::write_actual() -> void
{
    std::swap(send_, sending_);
    boost::asio::async_write(
        stream_,
        boost::asio::buffer(sending_),
        [self = shared_from_this()](boost::system::error_code const& error, std::size_t) {
            self->sending_.clear();
            if (not error && not self->send_.empty())
            {
                self->write_actual();
            }
        }
    );
}

auto connection::close() -> void
{
    resolver_.cancel();
    stream_.close();
}

namespace {

using tcp_type = boost::asio::ip::tcp::socket;
using tls_type = boost::asio::ssl::stream<Stream>;

/**
 * @brief Write SHA2-256 digest of the public-key to the output stream
 */
auto peer_fingerprint(std::ostream& os, SSL const* const ssl) -> void
{
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int md_len = 0; // if the digest somehow fails, use 0
    auto const cert = SSL_get0_peer_certificate(ssl);
    X509_pubkey_digest(cert, EVP_sha256(), md, &md_len);

    boost::io::ios_flags_saver const saver{os};

    // Server fingerprint representation
    os << std::hex << std::setfill('0');
    for (unsigned i = 0; i < md_len; i++)
    {
        os << std::setw(2) << int{md[i]};
    }
}

/**
 * @brief Set size of the read and write buffers on a TLS stream.
 *
 * @param stream TLS stream
 * @param n buffer size in bytes
 */
auto set_buffer_size(tls_type& stream, std::size_t const n) -> void
{
    auto const ssl = stream.native_handle();
    BIO_set_buffer_size(SSL_get_rbio(ssl), n);
    BIO_set_buffer_size(SSL_get_wbio(ssl), n);
}

/**
 * @brief Set size of the read and write buffers on a plain TCP stream.
 *
 * @param stream TCP stream
 * @param n buffer size in bytes
 */
auto set_buffer_size(tcp_type& socket, std::size_t const n) -> void
{
    socket.set_option(tcp_type::send_buffer_size{static_cast<int>(n)});
    socket.set_option(tcp_type::receive_buffer_size{static_cast<int>(n)});
}

auto set_buffer_size(boost::asio::local::stream_protocol::socket& socket, std::size_t const n) -> void
{
    socket.set_option(tcp_type::send_buffer_size{static_cast<int>(n)});
    socket.set_option(tcp_type::receive_buffer_size{static_cast<int>(n)});
}

/**
 * @brief Set the CLOEXEC flag on a file descriptor.
 *
 * Sets the flag to close a file descriptor on exec. This ensures
 * the file descriptor isn't inherited into any spawn processes.
 * This throws a system_error exception on failure.
 *
 * @param fd Open file descriptor
 */
auto set_cloexec(int const fd) -> void
{
    auto const flags = fcntl(fd, F_GETFD);
    if (-1 == flags)
    {
        throw std::system_error{errno, std::generic_category(), "failed to get file descriptor flags"};
    }
    if (-1 == fcntl(fd, F_SETFD, flags | FD_CLOEXEC))
    {
        throw std::system_error{errno, std::generic_category(), "failed to set file descriptor flags"};
    }
}

template <std::size_t... Ns>
auto constexpr sum() -> std::size_t { return (0 + ... + Ns); }

/**
 * @brief Builds the string format required for the ALPN extension
 *
 * @tparam Ns sizes of each protocol name
 * @param protocols array of the names of the supported protocols
 * @return encoded protocol names
 */
template <std::size_t... Ns>
auto constexpr alpn_encode(char const (&... protocols)[Ns]) -> std::array<unsigned char, sum<Ns...>()>
{
    auto result = std::array<unsigned char, sum<Ns...>()>{};
    auto cursor = std::begin(result);
    auto const encode = [&cursor]<std::size_t N>(char const(&protocol)[N]) {
        static_assert(N > 0, "Protocol name must be null-terminated");
        static_assert(N < 256, "Protocol name too long");
        if (protocol[N - 1] != '\0')
            throw "Protocol name not null-terminated";

        // Prefixed length byte
        *cursor++ = N - 1;

        // Add string skipping null terminator
        cursor = std::copy(std::begin(protocol), std::end(protocol) - 1, cursor);
    };
    (encode(protocols), ...);
    return result;
}

/**
 * @brief Throws a boost::system::system_error with the latest OpenSSL error.
 *
 * Retrieves the most recent OpenSSL error code, clears the OpenSSL error queue,
 * and throws a boost::system::system_error with the provided prefix and the error code.
 *
 * @param prefix A string to prefix the error message.
 * @throws boost::system::system_error Always throws with the OpenSSL error code and prefix.
 */
[[noreturn]] auto openssl_error(char const* const prefix) -> void
{
    boost::system::error_code ec{
        static_cast<int>(::ERR_get_error()),
        boost::asio::error::get_ssl_category()
    };

    ::ERR_clear_error();

    throw boost::system::system_error{ec, prefix};
}

} // namespace

auto connection::connect(
    Settings settings
) -> boost::asio::awaitable<std::string>
{
    // Fingerprint string builder
    std::ostringstream os;

    // replace previous socket and ensure it's a tcp socket
    
    // Establish underlying TCP connection
    switch (settings.base.index())
    {
        case 0: {
            auto& layer = std::get<0>(settings.base);
            auto& socket = stream_.reset_ip();
            auto const entries = co_await resolver_.async_resolve(layer.host, std::to_string(layer.port), boost::asio::use_awaitable);
            os << "tcp=" << co_await boost::asio::async_connect(socket, entries, boost::asio::use_awaitable);
            socket.set_option(boost::asio::ip::tcp::no_delay{true});
            set_buffer_size(socket, irc_buffer_size);
            set_cloexec(socket.native_handle());
            break;
        }
        case 1: {
            auto& layer = std::get<1>(settings.base);
            auto& socket = stream_.reset_local();
            boost::asio::local::stream_protocol::endpoint entry{layer.path};
            co_await socket.async_connect(entry, boost::asio::use_awaitable);
            os << "local";
            set_buffer_size(socket, irc_buffer_size);
            set_cloexec(socket.native_handle());
            break;
        }
        default:
            throw std::runtime_error{"Invalid base layer"};
    }

    for (auto&& layer : settings.layers)
    {
        switch (layer.index())
        {
        case 0: {
            auto const& tls_layer = std::get<0>(layer);
            boost::asio::ssl::context ssl_context{boost::asio::ssl::context::method::tls_client};
            ssl_context.set_default_verify_paths();

            // Upgrade stream_ to use TLS and invalidate socket
            auto& stream = stream_.upgrade(ssl_context);

            // Set the client certificate, if specified
            if (auto const client_cert = tls_layer.client_cert.get())
            {
                if (1 != SSL_use_certificate(stream.native_handle(), client_cert))
                {
                    openssl_error("SSL_use_certificate");
                }
            }

            // Set the client private key, if specified
            if (auto const client_key = tls_layer.client_key.get())
            {
                if (1 != SSL_use_PrivateKey(stream.native_handle(), client_key))
                {
                    openssl_error("SSL_use_PrivateKey");
                }
            }

            // Update the BIO buffer sizes
            set_buffer_size(stream, irc_buffer_size);

            // Configure ALPN
            {
                auto constexpr protos = alpn_encode("irc");
                // non-standard return behavior
                if (0 != SSL_set_alpn_protos(stream.native_handle(), protos.data(), protos.size()))
                {
                    // not documented to set an error code
                    throw std::runtime_error{"SSL_set_alpn_protos"};
                }
            }

            // Configure server certificate verification
            if (not tls_layer.verify.empty())
            {
                stream.set_verify_mode(boost::asio::ssl::verify_peer);
                stream.set_verify_callback(boost::asio::ssl::host_name_verification(tls_layer.verify));
            }

            // Set the SNI hostname, if specified
            if (not tls_layer.sni.empty())
            {
                if (1 != SSL_set_tlsext_host_name(stream.native_handle(), tls_layer.sni.c_str()))
                {
                    // not documented to set an error code
                    throw std::runtime_error{"SSL_set_tlsext_host_name"};
                }
            }

            // Configuration complete, initiate the handshake
            co_await stream.async_handshake(stream.client, boost::asio::use_awaitable);

            peer_fingerprint(os << " tls=", stream.native_handle());
            break;
        }
        case 1: {
            auto const& socks_layer = std::get<1>(layer);
            os << " socks="
               << co_await socks5::async_connect(
                      stream_,
                      socks_layer.host, socks_layer.port, std::move(socks_layer.auth),
                      boost::asio::use_awaitable
                  );
            break;
        }
        case 2: {
            auto const& http_layer = std::get<2>(layer);
            co_await httpconnect::async_connect(
                      stream_,
                      http_layer.host, http_layer.port,
                      boost::asio::use_awaitable
                  );
            os << " http";
            break;
        }
        default:
            throw std::runtime_error{"Bad layer?"};
        }
    }

    co_return os.str();
}
