#include "connection.hpp"

#include "cloexec.hpp"
#include "httpconnect.hpp"
#include "socks5.hpp"

#include <boost/io/ios_state.hpp>

#include <array>
#include <iomanip>
#include <vector>

connection::connection(boost::asio::io_context& io_context)
    : stream_{io_context}
{
}

auto connection::write(std::string_view const cmd) -> void
{
    if (not closed_ && not cmd.empty())
    {
        send_.insert(end(send_), begin(cmd), end(cmd));
        if (connected_ && sending_.empty())
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
    closed_ = true;
    connect_cancellation_.emit(boost::asio::cancellation_type::all);
    stream_.close();
}

namespace {

/**
 * @brief Write SHA2-256 digest of the public-key to the output stream
 */
auto peer_fingerprint(std::ostream& os, SSL const* const ssl) -> void
{
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int md_len = 0; // if the digest somehow fails, use 0
    auto const cert = SSL_get0_peer_certificate(ssl);
    if (cert)
    {
        X509_pubkey_digest(cert, EVP_sha256(), md, &md_len);
    }

    boost::io::ios_flags_saver const saver{os};

    // Server fingerprint representation
    os << std::hex << std::setfill('0');
    for (unsigned i = 0; i < md_len; i++)
    {
        os << std::setw(2) << int{md[i]};
    }
}

/**
 * @brief Request a size for the kernel send and receive buffers of a socket.
 *
 * This is a tuning hint: if the OS rejects the value the defaults are kept
 * and the connection proceeds.
 *
 * @param socket Connected socket
 * @param n buffer size in bytes
 */
template <typename Socket>
auto set_buffer_size(Socket& socket, std::size_t const n) -> void
{
    boost::system::error_code ignored;
    socket.set_option(typename Socket::send_buffer_size{static_cast<int>(n)}, ignored);
    socket.set_option(typename Socket::receive_buffer_size{static_cast<int>(n)}, ignored);
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

/**
 * @brief State shared by every layer while a connection is being established.
 */
struct ConnectContext
{
    /// The stream that each layer replaces or wraps
    Stream& stream;

    /// Aborts the TCP connection attempts when the connection is closed
    happy_eyeballs::CancellationSource& close_cancellation;

    /// The hostname that the most recent layer connected to. This is the
    /// default for TLS verification and SNI, and can be overridden by the
    /// TLS layer configuration.
    std::string& last_hostname;

    /// Fingerprint string builder
    std::ostream& os;
};

auto connect_layer(ConnectContext& ctx, IpLayer& layer) -> boost::asio::awaitable<void>
{
    ctx.last_hostname = layer.host;
    auto& socket = ctx.stream.reset_ip();
    auto const endpoint = co_await happy_eyeballs::async_connect(
        socket,
        layer.host,
        std::to_string(layer.port),
        ctx.close_cancellation
    );
    ctx.os << "tcp=" << endpoint;

    // The socket was opened close-on-exec by happy_eyeballs.
    boost::system::error_code ignored;
    socket.set_option(boost::asio::ip::tcp::no_delay{true}, ignored);
    set_buffer_size(socket, connection::irc_buffer_size);
}

auto connect_layer(ConnectContext& ctx, LocalLayer& layer) -> boost::asio::awaitable<void>
{
    // last_hostname stays empty - verification against a socket path doesn't make sense
    auto& socket = ctx.stream.reset_local();

    // Open close-on-exec so the descriptor can't leak into spawned processes
    boost::system::error_code open_error;
    open_cloexec(socket, boost::asio::local::stream_protocol{}, open_error);
    if (open_error)
    {
        throw boost::system::system_error{open_error, "socket"};
    }

    boost::asio::local::stream_protocol::endpoint entry{layer.path};
    co_await socket.async_connect(entry, boost::asio::use_awaitable);
    ctx.os << "local";
    set_buffer_size(socket, connection::irc_buffer_size);
}

auto connect_layer(ConnectContext& ctx, TlsLayer& tls_layer) -> boost::asio::awaitable<void>
{
    auto& stream = ctx.stream;
    auto& last_hostname = ctx.last_hostname;
    auto& os = ctx.os;

    boost::asio::ssl::context ssl_context{boost::asio::ssl::context::method::tls_client};
    ssl_context.set_default_verify_paths();

    // Refuse anything older than TLS 1.2 regardless of the OpenSSL build's defaults
    if (1 != SSL_CTX_set_min_proto_version(ssl_context.native_handle(), TLS1_2_VERSION))
    {
        openssl_error("SSL_CTX_set_min_proto_version");
    }

    // Upgrade stream_ to use TLS and invalidate socket
    auto& tls = stream.upgrade(ssl_context);

    // Set the client certificate, if specified
    if (auto const client_cert = tls_layer.client_cert.get())
    {
        if (1 != SSL_use_certificate(tls.native_handle(), client_cert))
        {
            openssl_error("SSL_use_certificate");
        }
    }

    // Set the client private key, if specified
    if (auto const client_key = tls_layer.client_key.get())
    {
        if (1 != SSL_use_PrivateKey(tls.native_handle(), client_key))
        {
            openssl_error("SSL_use_PrivateKey");
        }
    }

    // Configure ALPN
    {
        auto constexpr protos = alpn_encode("irc");
        // non-standard return behavior
        if (0 != SSL_set_alpn_protos(tls.native_handle(), protos.data(), protos.size()))
        {
            // not documented to set an error code
            throw std::runtime_error{"SSL_set_alpn_protos"};
        }
    }

    // Configure server certificate verification
    std::string const& verify = tls_layer.verify.value_or(last_hostname);
    if (not verify.empty())
    {
        tls.set_verify_mode(boost::asio::ssl::verify_peer);
        tls.set_verify_callback(boost::asio::ssl::host_name_verification(verify));
    }

    // Set the SNI hostname, if specified. RFC 6066 forbids literal IP
    // addresses in server_name, so those are never sent.
    std::string const& sni = tls_layer.sni.value_or(last_hostname);
    boost::system::error_code sni_ip_error;
    static_cast<void>(boost::asio::ip::make_address(sni, sni_ip_error));
    bool const sni_is_ip_literal = not sni_ip_error;
    if (not sni.empty() && not sni_is_ip_literal)
    {
        if (1 != SSL_set_tlsext_host_name(tls.native_handle(), sni.c_str()))
        {
            // not documented to set an error code
            throw std::runtime_error{"SSL_set_tlsext_host_name"};
        }
    }

    // Configuration complete, initiate the handshake
    co_await tls.async_handshake(tls.client, boost::asio::use_awaitable);

    peer_fingerprint(os << " tls=", tls.native_handle());
}

auto connect_layer(ConnectContext& ctx, SocksLayer& socks_layer) -> boost::asio::awaitable<void>
{
    ctx.last_hostname = socks_layer.host;
    ctx.os << " socks="
       << co_await socks5::async_connect(
              ctx.stream,
              socks_layer.host, socks_layer.port,
              std::move(socks_layer.auth),
              boost::asio::use_awaitable
          );
}

auto connect_layer(ConnectContext& ctx, HttpLayer& http_layer) -> boost::asio::awaitable<void>
{
    ctx.last_hostname = http_layer.host;
    ctx.os << " http";
    co_await httpconnect::async_connect(
        ctx.stream,
        http_layer.host, http_layer.port,
        std::move(http_layer.auth),
        boost::asio::use_awaitable
    );
}

} // namespace

auto connection::connect(
    Settings settings
) -> boost::asio::awaitable<std::string>
{
    if (closed_)
    {
        throw boost::system::system_error{boost::asio::error::operation_aborted};
    }

    // close() can arrive while the coroutine is suspended, including in the
    // window after a layer's last operation completed but before this
    // coroutine resumed (e.g. a winning TCP attempt that was already posted).
    // Anything established after close() must be torn down, not returned.
    auto const throw_if_closed = [this] {
        if (closed_)
        {
            stream_.close();
            throw boost::system::system_error{boost::asio::error::operation_aborted};
        }
    };

    std::ostringstream os;
    std::string last_hostname;
    ConnectContext ctx{stream_, connect_cancellation_, last_hostname, os};
    auto const connect_one = [&ctx](auto& layer) { return connect_layer(ctx, layer); };

    co_await std::visit(connect_one, settings.base);
    throw_if_closed();

    for (auto& layer : settings.layers)
    {
        co_await std::visit(connect_one, layer);
        throw_if_closed();
    }

    connected_ = true;
    if (not send_.empty())
    {
        write_actual();
    }

    co_return os.str();
}
