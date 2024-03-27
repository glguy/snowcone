#include "lua.hpp"

#include "../app.hpp"
#include "../linebuffer.hpp"
#include "../safecall.hpp"
#include "../userdata.hpp"

#include "irc_connection.hpp"
#include "../strings.hpp"

#include <ircmsg.hpp>

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <charconv> // from_chars
#include <memory>
#include <string>

namespace
{

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
            lua_pushstring(L, "irc handle destructed");
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
            size_t n;
            auto const cmd = luaL_checklstring(L, 2, &n);
            lua_settop(L, 2);
            auto const ref = luaL_ref(L, LUA_REGISTRYINDEX);
            irc->write(cmd, n, ref);

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

    struct BuildContextFailure
    {
        const char *operation;
        boost::system::error_code error;
    };

    auto build_ssl_context(
        std::string const &client_cert,
        std::string const &client_key,
        std::string const &client_key_password) -> std::variant<boost::asio::ssl::context, BuildContextFailure>;

    auto build_ssl_context(
        std::string const &client_cert,
        std::string const &client_key,
        std::string const &client_key_password) -> std::variant<boost::asio::ssl::context, BuildContextFailure>
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
                return BuildContextFailure{"password callback", error};
            }
        }
        if (not client_cert.empty())
        {
            ssl_context.use_certificate_file(client_cert, boost::asio::ssl::context::file_format::pem, error);
            if (error)
            {
                return BuildContextFailure{"certificate file", error};
            }
        }
        if (not client_key.empty())
        {
            ssl_context.use_private_key_file(client_key, boost::asio::ssl::context::file_format::pem, error);
            if (error)
            {
                return BuildContextFailure{"private key", error};
            }
        }
        return ssl_context;
    }

    auto handle_read(char *line, lua_State *L, int irc_cb) -> void
    {
        while (*line == ' ')
        {
            line++;
        }
        if (*line != '\0')
        {
            try
            {
                auto const msg = parse_irc_message(line); // might throw
                lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
                lua_pushstring(L, "MSG");
                pushircmsg(L, msg);
                safecall(L, "irc message", 2);
            }
            catch (irc_parse_error const &e)
            {
                lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
                lua_pushstring(L, "BAD");
                lua_pushinteger(L, static_cast<lua_Integer>(e.code));
                safecall(L, "irc parse error", 2);
            }
        }
    }

    auto pushirc(lua_State *const L, std::shared_ptr<irc_connection> irc) -> void
    {
        auto const w = new_udata<std::weak_ptr<irc_connection>>(L, 1, [L]()
                                                                {
        static luaL_Reg const MT[] {
            {"__gc", [](auto const L) {
                auto const w = check_udata<std::weak_ptr<irc_connection>>(L, 1);
                w->~weak_ptr();
                return 0;
            }},
            {},
        };
        static luaL_Reg const Methods[] {
            {"send", l_send_irc},
            {"close", l_close_irc},
            {}
        };
        luaL_setfuncs(L, MT, 0);
        luaL_newlib(L, Methods);
        lua_setfield(L, -2, "__index"); });
        std::construct_at(w, irc);
    }

    template <typename T>
    auto connect_thread(
        T params,
        auto &arg,
        boost::asio::io_context &io_context,
        std::shared_ptr<irc_connection> const irc,
        lua_State *const L,
        int irc_cb) -> boost::asio::awaitable<void>
    {
        try
        {
            std::ostringstream os;
            co_await params.connect(os, arg);
            {
                lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb); // function
                lua_pushstring(L, "CON");                  // argument 1
                push_string(L, os.str());                  // argument 2
                safecall(L, "successful connect", 2);
            }

            irc->write_thread();

            for (LineBuffer buff{irc_connection::irc_buffer_size};;)
            {
                auto target = buff.get_buffer();

                if (target.size() == 0)
                {
                    throw std::runtime_error{"line buffer full"};
                }

                bool need_flush = false;
                buff.add_bytes(
                    co_await irc->stream_->async_read_some(target, boost::asio::use_awaitable),
                    [L, irc_cb, &need_flush](auto const line)
                    {
                        handle_read(line, L, irc_cb);
                        need_flush = true;
                    });

                if (need_flush)
                {
                    lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
                    lua_pushstring(L, "FLUSH");
                    safecall(L, "irc parse error", 1);
                }
            }
        }
        catch (std::exception const &e)
        {
            lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
            lua_pushstring(L, "END");
            lua_pushstring(L, e.what());
            safecall(L, "end of connection", 2);
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

    luaL_checkany(L, 13); // callback
    lua_settop(L, 13);

    // consume the callback function and name it
    auto const irc_cb = luaL_ref(L, LUA_REGISTRYINDEX);

    auto const a = App::from_lua(L);
    auto &io_context = a->io_context;

    auto const with_socket_params = [tls, irc_cb, verify, sni, client_cert, client_key, client_key_password, &io_context, L, a](auto params) -> int
    {
        if (tls)
        {
            auto result = build_ssl_context(client_cert, client_key, client_key_password);
            if (auto *cxt = std::get_if<0>(&result))
            {
                auto const stream = std::make_shared<TlsStream<boost::asio::ip::tcp::socket>>
                (boost::asio::ssl::stream<boost::asio::ip::tcp::socket>{io_context, *cxt});
                stream->set_buffer_size(irc_connection::irc_buffer_size);

                auto const irc = std::make_shared<irc_connection>(io_context, a->L, irc_cb, stream);
                pushirc(L, irc);

                TlsConnectParams<decltype(params)> tlsParams;
                tlsParams.verify = verify;
                tlsParams.sni = sni;
                tlsParams.base = params;
                boost::asio::co_spawn(
                    io_context,
                    connect_thread(tlsParams, stream->get_stream(), io_context, irc, L, irc_cb), boost::asio::detached);
                return 1;
            }
            else
            {
                luaL_unref(L, LUA_REGISTRYINDEX, irc_cb);
                auto const &failure = std::get<1>(result);
                auto const message = failure.error.message();
                luaL_pushfail(L);
                lua_pushfstring(L, "%s: %s", failure.operation, message.c_str());
                return 2;
            }
        }
        else
        {
            auto const stream = std::make_shared<TcpStream>(boost::asio::ip::tcp::socket{io_context});
            auto const irc = std::make_shared<irc_connection>(io_context, a->L, irc_cb, stream);
            pushirc(L, irc);

            boost::asio::co_spawn(io_context,
                                  connect_thread(params, stream->get_stream(), io_context, irc, L, irc_cb), boost::asio::detached);

            return 1;
        }
    };

    if (strcmp(socks_host, "") && socks_port != 0)
    {
        SocksConnectParams<TcpConnectParams> params;
        
        // The IRC hostname and port is sent over to the SOCKS server
        params.host = host;
        params.port = port;
        
        params.auth = strcmp(socks_user, "") || strcmp(socks_pass, "")
                          ? socks5::Auth{socks5::UsernamePasswordCredential{socks_user, socks_pass}}
                          : socks5::Auth{socks5::NoCredential{}};
        
        // The underlying TCP connection is to the actual socks server
        params.base.host = socks_host;
        params.base.port = socks_port;
        
        return with_socket_params(params);
    }
    else
    {
        TcpConnectParams params;
        params.host = host;
        params.port = port;
        return with_socket_params(params);
    }
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
