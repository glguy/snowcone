#include "irc_connection.hpp"

#include <socks5.hpp>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include "../net/connect.hpp"

irc_connection::irc_connection(boost::asio::io_context& io_context, lua_State *L, stream_type&& stream)
    : write_timer{io_context, boost::asio::steady_timer::time_point::max()}
    , L{L}
    , stream_{std::move(stream)}
{
}

irc_connection::~irc_connection() {
    for (auto const ref : write_refs) {
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
    }
}

auto irc_connection::write(std::string_view const cmd, int const ref) -> void
{
    auto const idle = write_buffers.empty();
    write_buffers.emplace_back(cmd.data(), cmd.size());
    write_refs.push_back(ref);
    if (idle)
    {
        write_timer.cancel_one();
    }
}

auto irc_connection::write_thread() -> void
{
    if (write_buffers.empty())
    {
        write_timer.async_wait(
            [weak = weak_from_this()](auto)
            {
                if (auto const self = weak.lock())
                {
                    if (not self->write_buffers.empty())
                    {
                        self->write_thread_actual();
                    }
                }
            }
        );
    }
    else
    {
        write_thread_actual();
    }
}

auto irc_connection::write_thread_actual() -> void
{
    boost::asio::async_write(
        stream_,
        write_buffers,
        [weak = weak_from_this(), n = write_buffers.size()]
        (boost::system::error_code const& error, std::size_t)
        {
            if (not error)
            {
                if (auto const self = weak.lock())
                {
                    for (std::size_t i = 0; i < n; i++)
                    {
                        luaL_unref(self->L, LUA_REGISTRYINDEX, self->write_refs.front());
                        self->write_buffers.pop_front();
                        self->write_refs.pop_front();
                    }

                    self->write_thread();
                }
            }
        });
}

namespace {

auto set_buffer_size(boost::asio::ssl::stream<boost::asio::ip::tcp::socket>& stream, std::size_t const n) -> void
{
    auto const ssl = stream.native_handle();
    BIO_set_buffer_size(SSL_get_rbio(ssl), n);
    BIO_set_buffer_size(SSL_get_wbio(ssl), n);
}

auto set_buffer_size(boost::asio::ip::tcp::socket& socket, std::size_t const size) -> void
{
    socket.set_option(boost::asio::ip::tcp::socket::send_buffer_size{static_cast<int>(size)});
    socket.set_option(boost::asio::ip::tcp::socket::receive_buffer_size{static_cast<int>(size)});
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

auto build_ssl_context(
    std::string const &client_cert,
    std::string const &client_key,
    std::string const &client_key_password) -> boost::asio::ssl::context
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

auto irc_connection::connect(
    Settings settings
) -> boost::asio::awaitable<std::string>
{
    std::ostringstream os;

    // If we're going to use SOCKS then the TCP connection host is actually the socks
    // server and then the IRC server gets passed over the SOCKS protocol
    auto const use_socks = not settings.socks_host.empty() && settings.socks_port != 0;
    if (use_socks) {
        std::swap(settings.host, settings.socks_host);
        std::swap(settings.port, settings.socks_port);
    }

    auto& socket = std::get<boost::asio::ip::tcp::socket>(stream_.get_impl());

    // Optionally bind the local socket
    if (not settings.bind_host.empty() || settings.bind_port != 0)
    {
        co_await tcp_bind(socket, settings.bind_host, settings.bind_port);
    }

    // Establish underlying TCP connection
    {
        co_await tcp_connect(socket, settings.host, settings.port);
        // Connecting will create the actual socket, so set buffer size afterward
        set_buffer_size(socket, irc_connection::irc_buffer_size);
        set_cloexec(socket.native_handle());
        os << "tcp=" << socket.remote_endpoint();
    }

    // Optionally negotiate SOCKS connection
    if (use_socks) {
        auto auth = not settings.socks_user.empty() || not settings.socks_pass.empty()
                ? socks5::Auth{socks5::UsernamePasswordCredential{settings.socks_user, settings.socks_pass}}
                : socks5::Auth{socks5::NoCredential{}};
        auto const endpoint =
            co_await socks5::async_connect(
                socket, settings.socks_host, settings.socks_port, std::move(auth),
                boost::asio::use_awaitable);
        os << " socks=" << endpoint;
    }

    // Optionally negotiate TLS session
    if (settings.tls)
    {
        auto cxt = build_ssl_context(settings.client_cert, settings.client_key, settings.client_key_password);
        boost::asio::ssl::stream<boost::asio::ip::tcp::socket> stream {std::move(socket), cxt};
        set_buffer_size(stream, irc_connection::irc_buffer_size);
        co_await tls_connect(stream, settings.verify, settings.sni);
        peer_fingerprint(os << " tls=", stream.native_handle());
        stream_.get_impl() = std::move(stream);
    }

    co_return os.str();
}
