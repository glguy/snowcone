#include "irc_connection.hpp"

#include <socks5.hpp>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <boost/io/ios_state.hpp>

#include <array>
#include <iomanip>
#include <vector>

irc_connection::irc_connection(
    Private,
    boost::asio::io_context& io_context,
    lua_State* const L
)
    : stream_{io_context}
    , resolver_{io_context}
    , L{L}
    , writing_{false}
{
}

irc_connection::~irc_connection()
{
    for (auto const ref : write_refs)
    {
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
    }
}

auto irc_connection::write(std::string_view const cmd, int const ref) -> void
{
    write_buffers.emplace_back(cmd.data(), cmd.size());
    write_refs.emplace_back(ref);
    if (not writing_)
    {
        writing_ = true;
        write_actual();
    }
}

auto irc_connection::write_actual() -> void
{
    boost::asio::async_write(
        stream_,
        write_buffers,
        [weak = weak_from_this(), L = L, refs = std::move(write_refs)](boost::system::error_code const& error, std::size_t) {
            for (auto const ref : refs)
            {
                luaL_unref(L, LUA_REGISTRYINDEX, ref);
            }
            if (not error)
            {
                if (auto const self = weak.lock())
                {
                    if (self->write_buffers.empty())
                    {
                        self->writing_ = false;
                    }
                    else
                    {
                        self->write_actual();
                    }
                }
            }
        }
    );
    write_buffers.clear();
    write_refs.clear();
}

auto irc_connection::close() -> void
{
    resolver_.cancel();
    stream_.close();
}

namespace {

using tcp_type = boost::asio::ip::tcp::socket;
using tls_type = boost::asio::ssl::stream<tcp_type>;

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

} // namespace

auto irc_connection::connect(Settings settings) -> boost::asio::awaitable<std::string>
{
    // Fingerprint string builder
    std::ostringstream os;

    // replace previous socket and ensure it's a tcp socket
    auto& socket = stream_.reset();

    // If we're going to use SOCKS then the TCP connection host is actually the socks
    // server and then the IRC server gets passed over the SOCKS protocol
    auto const use_socks = not settings.socks_host.empty() && settings.socks_port != 0;
    if (use_socks)
    {
        std::swap(settings.host, settings.socks_host);
        std::swap(settings.port, settings.socks_port);
    }

    // Establish underlying TCP connection
    {
        auto const entries = co_await resolver_.async_resolve(settings.host, std::to_string(settings.port), boost::asio::use_awaitable);

        os << "tcp=" << co_await boost::asio::async_connect(socket, entries, boost::asio::use_awaitable);

        socket.set_option(boost::asio::ip::tcp::no_delay{true});
        set_buffer_size(socket, irc_buffer_size);
        set_cloexec(socket.native_handle());
    }

    // Optionally negotiate SOCKS connection
    if (use_socks)
    {
        os << " socks="
           << co_await socks5::async_connect(
                  socket,
                  settings.socks_host, settings.socks_port, std::move(settings.socks_auth),
                  boost::asio::use_awaitable
              );
    }

    // Optionally negotiate TLS session
    if (settings.tls)
    {
        boost::asio::ssl::context ssl_context{boost::asio::ssl::context::method::tls_client};
        ssl_context.set_default_verify_paths();

        // Upgrade stream_ to use TLS and invalidate socket
        auto& stream = stream_.upgrade(ssl_context);

        // Set the client certificate, if specified
        if (auto const client_cert = settings.client_cert.get())
        {
            if (1 != SSL_use_certificate(stream.native_handle(), client_cert))
            {
                throw std::runtime_error{"certificate file"};
            }
        }

        // Set the client private key, if specified
        if (auto const client_key = settings.client_key.get())
        {
            if (1 != SSL_use_PrivateKey(stream.native_handle(), client_key))
            {
                throw std::runtime_error{"private key"};
            }
        }

        // Update the BIO buffer sizes
        set_buffer_size(stream, irc_buffer_size);

        // Configure ALPN
        {
            auto constexpr protos = alpn_encode("irc");
            SSL_set_alpn_protos(stream.native_handle(), protos.data(), protos.size());
        }

        // Configure server certificate verification
        if (not settings.verify.empty())
        {
            stream.set_verify_mode(boost::asio::ssl::verify_peer);
            stream.set_verify_callback(boost::asio::ssl::host_name_verification(settings.verify));
        }

        // Set the SNI hostname, if specified
        if (not settings.sni.empty())
        {
            SSL_set_tlsext_host_name(stream.native_handle(), settings.sni.c_str());
        }

        // Configuration complete, initiate the handshake
        co_await stream.async_handshake(stream.client, boost::asio::use_awaitable);

        peer_fingerprint(os << " tls=", stream.native_handle());
    }

    co_return os.str();
}
