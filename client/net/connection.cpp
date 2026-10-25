#include "connection.hpp"

#include "cloexec.hpp"
#include "httpconnect.hpp"
#include "socks5.hpp"

#include <boost/io/ios_state.hpp>

#include <iomanip>
#include <memory>
#include <stdexcept>
#include <string>
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
 * @brief Throws a boost::system::system_error for the failed OpenSSL call.
 *
 * Reports the most recently queued OpenSSL error, the one the failed call
 * added, then clears the queue so nothing stale is reported later. A call
 * that failed without queueing anything is reported as a generic failure
 * rather than as error 0.
 *
 * @param prefix Name of the failed call
 * @throws boost::system::system_error Always
 */
[[noreturn]] auto openssl_error(char const* const prefix) -> void
{
    auto const code = ::ERR_peek_last_error();
    ::ERR_clear_error();

    if (code == 0)
    {
        throw std::runtime_error{std::string{prefix} + ": failed"};
    }

    boost::system::error_code const ec{
        static_cast<int>(code),
        boost::asio::error::get_ssl_category()
    };
    throw boost::system::system_error{ec, prefix};
}

/**
 * @brief Write the SHA-256 digest of the peer's DER SubjectPublicKeyInfo
 *
 * This matches common pinning tools, for example
 * `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | sha256sum`.
 */
auto peer_fingerprint(std::ostream& os, SSL const* const ssl) -> void
{
    auto const cert = SSL_get0_peer_certificate(ssl);
    if (not cert)
    {
        // Only possible for anonymous ciphers, which aren't enabled
        throw std::runtime_error{"TLS peer sent no certificate"};
    }

    unsigned char* der = nullptr;
    auto const der_len = i2d_PUBKEY(X509_get0_pubkey(cert), &der);
    if (der_len <= 0)
    {
        openssl_error("i2d_PUBKEY");
    }
    std::unique_ptr<unsigned char, decltype([](unsigned char* p) { OPENSSL_free(p); })> const der_owner{der};

    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int md_len = 0;
    if (1 != EVP_Digest(der, der_len, md, &md_len, EVP_sha256(), nullptr))
    {
        openssl_error("EVP_Digest");
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

/**
 * @brief Builds the wire format of the ALPN extension: each name prefixed
 * with its length byte
 *
 * @param protocols names, each 1 to 255 bytes
 * @return encoded protocol names
 */
auto alpn_encode(std::vector<std::string> const& protocols) -> std::vector<unsigned char>
{
    std::vector<unsigned char> result;
    for (auto const& protocol : protocols)
    {
        result.push_back(static_cast<unsigned char>(protocol.size()));
        result.insert(result.end(), protocol.begin(), protocol.end());
    }
    return result;
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

    /// Fingerprint string builder
    std::ostream& os;
};

auto connect_layer(ConnectContext& ctx, IpLayer& layer) -> boost::asio::awaitable<void>
{
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

    // Configure ALPN, only when asked: an unexpected protocol name can make a
    // server or proxy refuse the handshake
    if (not tls_layer.alpn.empty())
    {
        auto const protos = alpn_encode(tls_layer.alpn);
        // non-standard return behavior
        if (0 != SSL_set_alpn_protos(tls.native_handle(), protos.data(), protos.size()))
        {
            // not documented to set an error code
            throw std::runtime_error{"SSL_set_alpn_protos"};
        }
    }

    // Configure server certificate verification
    // OpenSSL checks the name itself, so a mismatch is recorded as the
    // verify result and can be reported
    if (not tls_layer.verify.empty())
    {
        tls.set_verify_mode(boost::asio::ssl::verify_peer);
        auto const name = tls_names::verification(tls_layer.verify);
        auto const param = SSL_get0_param(tls.native_handle());
        boost::system::error_code not_ip;
        static_cast<void>(boost::asio::ip::make_address(name, not_ip));
        if (not_ip)
        {
            if (1 != X509_VERIFY_PARAM_set1_host(param, name.data(), name.size()))
            {
                openssl_error("X509_VERIFY_PARAM_set1_host");
            }
        }
        else if (1 != X509_VERIFY_PARAM_set1_ip_asc(param, name.c_str()))
        {
            openssl_error("X509_VERIFY_PARAM_set1_ip_asc");
        }
    }

    // Set the SNI hostname, if specified
    if (auto const sni = tls_names::server_name(tls_layer.sni))
    {
        if (1 != SSL_set_tlsext_host_name(tls.native_handle(), sni->c_str()))
        {
            // not documented to set an error code
            throw std::runtime_error{"SSL_set_tlsext_host_name"};
        }
    }

    // Configuration complete, initiate the handshake
    boost::system::error_code handshake_error;
    co_await tls.async_handshake(tls.client, boost::asio::redirect_error(boost::asio::use_awaitable, handshake_error));
    if (handshake_error)
    {
        // OpenSSL computes a verify result even with verification off, so
        // it explains the failure only when verification was on
        auto const result = SSL_get_verify_result(tls.native_handle());
        if (not tls_layer.verify.empty() && result != X509_V_OK)
        {
            throw boost::system::system_error{handshake_error, X509_verify_cert_error_string(result)};
        }
        throw boost::system::system_error{handshake_error};
    }

    peer_fingerprint(os << " tls=", tls.native_handle());
}

/// IP literals are sent to the proxy as addresses rather than as domain names
auto socks_host(std::string const& host) -> socks5::Host
{
    // A scope (fe80::1%eth0) names an interface on the proxy host. SOCKS5
    // addresses can't carry one, so let the proxy resolve it as a name.
    if (host.find('%') != std::string::npos)
    {
        return host;
    }

    boost::system::error_code ec;
    auto const address = boost::asio::ip::make_address(host, ec);
    if (ec)
    {
        return host;
    }
    return address;
}

auto connect_layer(ConnectContext& ctx, SocksLayer& socks_layer) -> boost::asio::awaitable<void>
{
    ctx.os << " socks="
       << co_await socks5::async_connect(
              ctx.stream,
              socks_host(socks_layer.host), socks_layer.port,
              std::move(socks_layer.auth),
              boost::asio::use_awaitable
          );
}

auto connect_layer(ConnectContext& ctx, HttpLayer& http_layer) -> boost::asio::awaitable<void>
{
    ctx.os << " http";
    co_await httpconnect::async_connect(
        ctx.stream,
        http_layer.host, http_layer.port,
        std::move(http_layer.auth),
        boost::asio::use_awaitable
    );
}

} // namespace

auto tls_names::verification(std::string const& host) -> std::string
{
    boost::system::error_code ec;
    auto const address = boost::asio::ip::make_address(host, ec);
    if (ec or not address.is_v6())
    {
        return host;
    }
    return boost::asio::ip::address_v6{address.to_v6().to_bytes()}.to_string();
}

auto tls_names::server_name(std::string const& host) -> std::optional<std::string>
{
    boost::system::error_code ec;
    static_cast<void>(boost::asio::ip::make_address(host, ec));
    if (host.empty() or not ec)
    {
        return std::nullopt;
    }
    return host;
}

auto tls_names::resolve(
    std::optional<std::string_view> const verify,
    std::optional<std::string_view> const sni,
    std::string_view const host
) -> Names
{
    auto const named = [](std::optional<std::string_view> const name) {
        return name && not name->empty();
    };
    return Names{
        .verify = std::string{verify ? *verify : named(sni) ? *sni : host},
        .sni = std::string{sni ? *sni : named(verify) ? *verify : host},
    };
}

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
    ConnectContext ctx{stream_, connect_cancellation_, os};
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
