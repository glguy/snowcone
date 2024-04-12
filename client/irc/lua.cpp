#include "lua.hpp"

#include "../app.hpp"
#include "../linebuffer.hpp"
#include "../safecall.hpp"
#include "../userdata.hpp"

#include "irc_connection.hpp"
#include "../net/connect.hpp"
#include "../strings.hpp"

#include <ircmsg.hpp>

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <charconv> // from_chars
#include <memory>
#include <system_error>
#include <string>
#include <variant>
#include <fcntl.h>

namespace
{

using namespace std::literals::string_view_literals;

using socket_type = boost::asio::ip::tcp::socket;
using tls_type = boost::asio::ssl::stream<socket_type>;

auto l_close_irc(lua_State *const L) -> int
{
    auto const w = check_udata<std::weak_ptr<irc_connection>>(L, 1);

    if (auto const irc = w->lock())
    {
        irc->close();
        lua_pushboolean(L, 1);
        return 1;
    }
    else
    {
        luaL_pushfail(L);
        push_string(L, "irc handle destructed"sv);
        return 2;
    }
}

auto l_send_irc(lua_State *const L) -> int
{
    auto const w = check_udata<std::weak_ptr<irc_connection>>(L, 1);

    if (auto const irc = w->lock())
    {
        // Wait until after luaL_error to start putting things on the
        // stack that have destructors
        auto const cmd = check_string_view(L, 2);
        lua_settop(L, 2);
        auto const ref = luaL_ref(L, LUA_REGISTRYINDEX);
        irc->write(cmd, ref);

        lua_pushboolean(L, 1);
        return 1;
    }
    else
    {
        luaL_pushfail(L);
        luaL_error(L, "irc handle destructed");
        return 2;
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

auto pushirc(lua_State *const L, std::weak_ptr<irc_connection> irc) -> void
{
    auto const w = new_udata<std::weak_ptr<irc_connection>>(L, 1, [L]()
    {
        luaL_Reg const MT[] {
            {"__gc", [](auto const L) {
                auto const w = check_udata<std::weak_ptr<irc_connection>>(L, 1);
                w->~weak_ptr();
                return 0;
            }},
            {},
        };
        luaL_setfuncs(L, MT, 0);

        // Setup class methods for IRC objects
        luaL_Reg const Methods[] {
            {"send", l_send_irc},
            {"close", l_close_irc},
            {}
        };
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
    });
    std::construct_at(w, irc);
}

struct Settings
{
    bool tls;
    std::string host;
    std::uint16_t port;

    std::string client_cert;
    std::string client_key;
    std::string client_key_password;
    std::string verify;
    std::string sni;

    std::string socks_host;
    std::uint16_t socks_port;
    std::string socks_user;
    std::string socks_pass;

    std::string bind_host;
    std::uint16_t bind_port;
};


auto set_buffer_size(tls_type& stream, std::size_t const n) -> void
{
    auto const ssl = stream.native_handle();
    BIO_set_buffer_size(SSL_get_rbio(ssl), n);
    BIO_set_buffer_size(SSL_get_wbio(ssl), n);
}

auto set_buffer_size(socket_type& socket, std::size_t const size) -> void
{
    socket.set_option(socket_type::send_buffer_size{static_cast<int>(size)});
    socket.set_option(socket_type::receive_buffer_size{static_cast<int>(size)});
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

auto connect(
    App& app,
    std::shared_ptr<irc_connection> irc,
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

    // Establish underlying TCP connection
    {
        auto& socket = std::get<socket_type>(irc->get_stream().get_impl());
        co_await tcp_connect(os, socket, settings.host, settings.port, settings.bind_host, settings.bind_port);
        // Connecting will create the actual socket, so set buffer size afterward
        set_buffer_size(socket, irc_connection::irc_buffer_size);
        set_cloexec(socket.native_handle());
    }

    // Optionally negotiate SOCKS connection
    if (use_socks) {
        auto auth = not settings.socks_user.empty() || not settings.socks_pass.empty()
                ? socks5::Auth{socks5::UsernamePasswordCredential{std::move(settings.socks_user), std::move(settings.socks_pass)}}
                : socks5::Auth{socks5::NoCredential{}};
        os << " socks=";
        os << co_await socks5::async_connect(
            irc->get_stream(),
            std::move(settings.socks_host),
            settings.port,
            std::move(auth),
            boost::asio::use_awaitable);
    }

    // Optionally negotiate TLS session
    if (settings.tls)
    {
        auto cxt = build_ssl_context(settings.client_cert, settings.client_key, settings.client_key_password);
        tls_type stream {std::move(std::get<socket_type>(irc->get_stream().get_impl())), cxt};
        set_buffer_size(stream, irc_connection::irc_buffer_size);
        co_await tls_connect(os << " ", stream, settings.verify, settings.sni);
        irc->get_stream().get_impl() = std::move(stream);
    }

    co_return os.str();
}

auto session_thread(
    App& app,
    int irc_cb,
    std::shared_ptr<irc_connection> irc,
    Settings settings
) -> boost::asio::awaitable<void>
{
    auto const L = app.get_lua();

    {
        auto const fingerprint = co_await connect(app, irc, std::move(settings));
        lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
        push_string(L, "CON"sv);
        push_string(L, fingerprint);
        safecall(L, "successful connect", 2);
    }

    irc->write_thread();

    for (LineBuffer buff{irc_connection::irc_buffer_size};;)
    {
        auto const target = buff.get_buffer();
        if (target.size() == 0)
        {
            throw std::runtime_error{"line buffer full"};
        }

        bool need_flush = false;
        buff.add_bytes(co_await irc->get_stream().async_read_some(target, boost::asio::use_awaitable));
        while (auto line = buff.next_line())
        {
            // skip leading whitespace and ignore empty lines
            while (*line == ' ') { line++; }
            if (*line != '\0')
            {
                auto const msg = parse_irc_message(line); // might throw
                lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
                push_string(L, "MSG"sv);
                pushircmsg(L, msg);
                safecall(L, "irc message", 2);
                need_flush = true;
            }
        }

        if (need_flush)
        {
            lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
            push_string(L, "FLUSH"sv);
            safecall(L, "irc parse error", 1);
        }
    }
}

} // namespace

auto l_start_irc(lua_State *const L) -> int
{
    auto const tls = lua_toboolean(L, 1);
    auto const host = luaL_checkstring(L, 2);
    auto const port = luaL_checkinteger(L, 3);
    auto const client_cert = luaL_optlstring(L, 4, "", nullptr);
    auto const client_key = luaL_optlstring(L, 5, client_cert, nullptr);
    auto const client_key_password = luaL_optlstring(L, 6, "", nullptr);
    auto const verify = luaL_optlstring(L, 7, host, nullptr);
    auto const sni = luaL_optlstring(L, 8, host, nullptr);
    auto const socks_host = luaL_optlstring(L, 9, "", nullptr);
    auto const socks_port = luaL_optinteger(L, 10, 0);
    auto const socks_user = luaL_optlstring(L, 11, "", nullptr);
    auto const socks_pass = luaL_optlstring(L, 12, "", nullptr);
    auto const bind_host = luaL_optlstring(L, 13, "", nullptr);
    auto const bind_port = luaL_optinteger(L, 14, 0);
    luaL_checkany(L, 15); // callback
    lua_settop(L, 15);
    luaL_argcheck(L, 1 <= port && port <= 0xffff, 3, "port out of range");
    luaL_argcheck(L, 0 <= socks_port && socks_port <= 0xffff, 10, "port out of range");
    luaL_argcheck(L, 0 <= bind_port && bind_port <= 0xffff, 14, "port out of range");

    auto const irc_cb = luaL_ref(L, LUA_REGISTRYINDEX);

    Settings settings = {
        .tls = static_cast<bool>(tls),
        .host = host,
        .port = static_cast<std::uint16_t>(port),
        .client_cert = client_cert,
        .client_key = client_key,
        .client_key_password = client_key_password,
        .verify = verify,
        .sni = sni,
        .socks_host = socks_host,
        .socks_port = static_cast<std::uint16_t>(socks_port),
        .socks_user = socks_user,
        .socks_pass = socks_pass,
        .bind_host = bind_host,
        .bind_port = static_cast<std::uint16_t>(bind_port),
    };

    auto& a = *App::from_lua(L);
    auto& io_context = a.get_executor();

    auto const irc = std::make_shared<irc_connection>(
        io_context,
        L,
        irc_connection::stream_type{socket_type{io_context}}
    );
    pushirc(L, irc);

    boost::asio::co_spawn(
        io_context, session_thread(a, irc_cb, irc, std::move(settings)),
        [&a, irc_cb](std::exception_ptr const e) {
            auto const L = a.get_lua();

            lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
            luaL_unref(a.get_lua(), LUA_REGISTRYINDEX, irc_cb);
            push_string(L, "END"sv);

            try {
                std::rethrow_exception(e);
            } catch (std::exception const& ex) {
                push_string(L, ex.what());
            } catch (...) {
                lua_pushnil(L);
            }

            safecall(L, "end of connection", 2);
        }
    );

    return 1;
}

auto pushircmsg(lua_State *const L, ircmsg const &msg) -> void
{
    lua_createtable(L, msg.args.size(), 3);
    pushtags(L, msg.tags);
    lua_setfield(L, -2, "tags");

    if (msg.hassource())
    {
        push_string(L, msg.source);
        lua_setfield(L, -2, "source");
    }

    int code;
    auto res = std::from_chars(msg.command.begin(), msg.command.end(), code);
    if (*res.ptr == '\0')
    {
        lua_pushinteger(L, code);
    }
    else
    {
        push_string(L, msg.command);
    }
    lua_setfield(L, -2, "command");

    int argix = 1;
    for (auto const arg : msg.args)
    {
        push_string(L, arg);
        lua_rawseti(L, -2, argix++);
    }
}

auto pushtags(lua_State *const L, std::vector<irctag> const &tags) -> void
{
    lua_createtable(L, 0, tags.size());
    for (auto &&tag : tags)
    {
        push_string(L, tag.key);
        push_string(L, tag.val);
        lua_settable(L, -3);
    }
}

template <>
char const *udata_name<std::weak_ptr<irc_connection>> = "irc_connection";
