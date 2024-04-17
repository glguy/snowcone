#include "connect.hpp"

#include <boost/asio.hpp>
#include <boost/io/ios_state.hpp>

#include <array>
#include <iomanip>
#include <vector>

namespace {

using tcp_type = boost::asio::ip::tcp::socket;
using tls_type = boost::asio::ssl::stream<tcp_type>;

/**
 * @brief Set up certificate verification, SNI, and perform TLS handshake
 *
 * @param stream
 * @param verify optional hostname to verify on server certificate
 * @param sni optional hostname to send for SNI
 */
auto tls_connect(
    tls_type& stream,
    std::string const& verify,
    std::string const& sni
) -> boost::asio::awaitable<void>
{
    if (not verify.empty())
    {
        stream.set_verify_mode(boost::asio::ssl::verify_peer);
        stream.set_verify_callback(boost::asio::ssl::host_name_verification(verify));
    }

    if (not sni.empty())
    {
        SSL_set_tlsext_host_name(stream.native_handle(), sni.c_str());
    }
    co_await stream.async_handshake(stream.client, boost::asio::use_awaitable);
}

/**
 * @brief Write SHA2-256 digest of the public-key to the output stream
 */
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

/**
 * @brief Bind the socket to a specific local IP address or port
 */
auto tcp_bind(
    tcp_type& stream,
    std::string_view const host,
    std::uint16_t const port
) -> boost::asio::awaitable<void>
{
    auto resolver = boost::asio::ip::tcp::resolver{stream.get_executor()};
    auto const entries =
        co_await resolver.async_resolve(host, std::to_string(port), boost::asio::use_awaitable);
    auto const &entry = *entries.begin();
    stream.open(entry.endpoint().protocol());
    stream.bind(entry);
}

/**
 * @brief Establish a new TCP connection to the given remote hostname and port
 */
auto tcp_connect(
    tcp_type& stream,
    std::string_view const host,
    std::uint16_t const port
) -> boost::asio::awaitable<boost::asio::ip::tcp::endpoint>
{
    auto resolver = boost::asio::ip::tcp::resolver{stream.get_executor()};
    auto const entries =
        co_await resolver.async_resolve(host, std::to_string(port), boost::asio::use_awaitable);

    co_return co_await boost::asio::async_connect(stream, entries, boost::asio::use_awaitable);
}

auto set_buffer_size(tls_type& stream, std::size_t const n) -> void
{
    auto const ssl = stream.native_handle();
    BIO_set_buffer_size(SSL_get_rbio(ssl), n);
    BIO_set_buffer_size(SSL_get_wbio(ssl), n);
}

auto set_buffer_size(tcp_type& socket, std::size_t const n) -> void
{
    socket.set_option(tcp_type::send_buffer_size{static_cast<int>(n)});
    socket.set_option(tcp_type::receive_buffer_size{static_cast<int>(n)});
}

auto set_cloexec(int const fd) -> void
{
    auto const flags = fcntl(fd, F_GETFD);
    if (-1 == flags) {
        throw std::system_error{errno, std::generic_category(), "failed to get file descriptor flags"};
    }
    if (-1 == fcntl(fd, F_SETFD, flags | FD_CLOEXEC)) {
        throw std::system_error{errno, std::generic_category(), "failed to set file descriptor flags"};
    }
}

template <std::size_t... Ns>
auto constexpr sum() -> std::size_t { return (0 + ... + Ns); }

/**
 * @brief Build's the string format required for the ALPN extension
 *
 * @tparam Ns sizes of each protocol name
 * @return encoded protocol names
 */
template<std::size_t... Ns>
auto constexpr alpn_encode(const char(&...protocols)[Ns]) -> std::array<unsigned char, sum<Ns...>()>
{
    auto result = std::array<unsigned char, sum<Ns...>()>{};
    auto cursor = std::begin(result);
    auto const encode = [&cursor]<std::size_t N>(char const (&protocol)[N])
    {
        static_assert(N > 0, "Protocol name must be null-terminated");
        static_assert(N < 256, "Protocol name too long");
        if (protocol[N-1] != '\0') throw "Protocol name not null-terminated";

        // Prefixed length byte
        *cursor++ = N - 1;

        // Add string skipping null terminator
        cursor = std::copy(std::begin(protocol), std::end(protocol) - 1, cursor);
    };
    (encode(protocols), ...);
    return result;
}

auto set_alpn(tls_type& stream) -> void
{
    auto constexpr protos = alpn_encode("irc");
    SSL_set_alpn_protos(stream.native_handle(), protos.data(), protos.size());
}

auto build_ssl_context(
    std::string const &client_cert,
    std::string const &client_key,
    std::string const &client_key_password
) -> boost::asio::ssl::context
{
    boost::system::error_code error;
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
            },
            error);
        if (error)
        {
            throw std::runtime_error{"password callback: " + error.to_string()};
        }
    }
    if (not client_cert.empty())
    {
        ssl_context.use_certificate_file(client_cert, boost::asio::ssl::context::file_format::pem, error);
        if (error)
        {
            throw std::runtime_error{"certificate file: " + error.to_string()};
        }
    }
    if (not client_key.empty())
    {
        ssl_context.use_private_key_file(client_key, boost::asio::ssl::context::file_format::pem, error);
        if (error)
        {
            throw std::runtime_error{"private key: " + error.to_string()};
        }
    }
    return ssl_context;
}

} // namespace

auto connect_stream(
    boost::asio::io_context& io_context,
    Settings settings
) -> boost::asio::awaitable<std::pair<CommonStream, std::string>>
{
    std::ostringstream os;

    // If we're going to use SOCKS then the TCP connection host is actually the socks
    // server and then the IRC server gets passed over the SOCKS protocol
    auto const use_socks = not settings.socks_host.empty() && settings.socks_port != 0;
    if (use_socks) {
        std::swap(settings.host, settings.socks_host);
        std::swap(settings.port, settings.socks_port);
    }

    tcp_type socket{io_context};

    // Optionally bind the local socket
    if (not settings.bind_host.empty() || settings.bind_port != 0)
    {
        co_await tcp_bind(socket, settings.bind_host, settings.bind_port);
    }

    // Establish underlying TCP connection
    {
        os << "tcp=" << co_await tcp_connect(socket, settings.host, settings.port);
        socket.set_option(boost::asio::ip::tcp::no_delay(true));
        set_buffer_size(socket, settings.buffer_size);
        set_cloexec(socket.native_handle());
    }

    // Optionally negotiate SOCKS connection
    if (use_socks) {
        auto auth = not settings.socks_user.empty() || not settings.socks_pass.empty()
                ? socks5::Auth{socks5::UsernamePasswordCredential{settings.socks_user, settings.socks_pass}}
                : socks5::Auth{socks5::NoCredential{}};
        os << " socks="
           << co_await socks5::async_connect(
                socket, settings.socks_host, settings.socks_port, std::move(auth),
                boost::asio::use_awaitable);
    }

    // Optionally negotiate TLS session
    if (settings.tls)
    {
        auto cxt = build_ssl_context(settings.client_cert, settings.client_key, settings.client_key_password);
        tls_type stream {std::move(socket), cxt};
        set_buffer_size(stream, settings.buffer_size);
        set_alpn(stream);
        co_await tls_connect(stream, settings.verify, settings.sni);
        peer_fingerprint(os << " tls=", stream.native_handle());
        co_return std::pair{CommonStream{std::move(stream)}, os.str()};
    }
    else
    {
        co_return std::pair{CommonStream{std::move(socket)}, os.str()};
    }
}
