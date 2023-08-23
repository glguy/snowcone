#include "irc.hpp"

#include "app.hpp"
#include "linebuffer.hpp"
#include "luaref.hpp"
#include "safecall.hpp"

#include <ircmsg.hpp>

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <charconv> // from_chars
#include <list>
#include <memory>
#include <string>

namespace
{
    /**
     * @brief Push string_view value onto Lua stack
     *
     * @param L Lua
     * @param str string
     * @return char const* string in Lua memory
     */
    auto push_stringview(lua_State *const L, std::string_view const str) -> char const *
    {
        return lua_pushlstring(L, str.data(), str.size());
    }

auto pushircmsg(lua_State *const L, ircmsg const &msg) -> void
{
    lua_createtable(L, msg.args.size(), 3);
    pushtags(L, msg.tags);
    lua_setfield(L, -2, "tags");

    if (msg.hassource())
    {
        push_stringview(L, msg.source);
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
        push_stringview(L, msg.command);
    }
    lua_setfield(L, -2, "command");

    int argix = 1;
    for (auto const arg : msg.args)
    {
        push_stringview(L, arg);
        lua_rawseti(L, -2, argix++);
    }
}

class irc_connection : public std::enable_shared_from_this<irc_connection>
{
protected:
    boost::asio::io_context &io_context;
    lua_State *L;

    std::list<boost::asio::const_buffer> write_buffers;
    std::list<int> write_refs;

public:
    irc_connection(boost::asio::io_context &io_context, lua_State *L)
        : io_context{io_context}, L{L}
    {
    }

    virtual ~irc_connection() {}

    virtual auto shutdown() -> boost::system::error_code = 0;

    auto write_thread() -> boost::asio::awaitable<void>
    {
        do
        {
            auto n = write_buffers.size();
            co_await write_awaitable();
            for (; n > 0; n--)
            {
                luaL_unref(L, LUA_REGISTRYINDEX, write_refs.front());
                write_buffers.pop_front();
                write_refs.pop_front();
            }
        } while (not write_buffers.empty());
    }

    auto write(char const * const cmd, size_t const n, int const ref) -> void
    {
        auto const idle = write_buffers.empty();
        write_buffers.emplace_back(cmd, n);
        write_refs.push_back(ref);
        if (idle)
        {
            boost::asio::co_spawn(io_context, write_thread(),
                [self = shared_from_this()](std::exception_ptr error)
                {
                    if (error)
                    {
                        for (auto ref : self->write_refs)
                        {
                            luaL_unref(self->L, LUA_REGISTRYINDEX, ref);
                        }
                        self->write_refs.clear();
                        self->write_buffers.clear();
                    }
                });
        }
    }

    using await_size_t = boost::asio::awaitable<std::size_t>;
    auto virtual write_awaitable() -> await_size_t = 0;
    auto virtual read_awaitable(boost::asio::mutable_buffers_1 const& buffers) -> await_size_t = 0;
};

class plain_irc_connection final : public irc_connection
{
public:
    boost::asio::ip::tcp::socket socket_;

    plain_irc_connection(boost::asio::io_context &io_context, lua_State *const L)
        : irc_connection{io_context, L}, socket_{io_context}
    {
    }

    auto shutdown() -> boost::system::error_code override
    {
        boost::system::error_code ec;
        socket_.shutdown(boost::asio::ip::tcp::socket::shutdown_send, ec);
        return ec;
    }

    auto write_awaitable() -> await_size_t override
    {
        return boost::asio::async_write(socket_, write_buffers, boost::asio::use_awaitable);
    }

    auto read_awaitable(
        boost::asio::mutable_buffers_1 const& buffers
    ) -> await_size_t override
    {
        return socket_.async_read_some(buffers, boost::asio::use_awaitable);
    }
};

class tls_irc_connection : public irc_connection
{
public:
    boost::asio::ssl::stream<boost::asio::ip::tcp::socket> socket_;

    tls_irc_connection(
        boost::asio::io_context &io_context,
        boost::asio::ssl::context &ssl_context,
        lua_State *const L)
    : irc_connection{io_context, L}, socket_{io_context, ssl_context}
    {
    }

    auto shutdown() -> boost::system::error_code override
    {
        boost::system::error_code ec;
        socket_.shutdown(ec);
        return ec;
    }

    auto write_awaitable() -> await_size_t override
    {
        return boost::asio::async_write(socket_, write_buffers, boost::asio::use_awaitable);
    }

    auto read_awaitable(boost::asio::mutable_buffers_1 const& buffers) -> await_size_t override
    {
        return socket_.async_read_some(buffers, boost::asio::use_awaitable);
    }
};

auto on_send_irc(lua_State * const L) -> int
{
    auto const tcp = reinterpret_cast<irc_connection *>(lua_touserdata(L, lua_upvalueindex(1)));

    if (tcp == nullptr)
    {
        luaL_error(L, "send to closed irc");
        return 0;
    }

    size_t n;
    auto const cmd = luaL_optlstring(L, 1, nullptr, &n);
    lua_settop(L, 1);

    if (cmd == nullptr)
    {
        auto const error = tcp->shutdown();
        if (error) {
            lua_pushnil(L);
            lua_pushstring(L, error.what().c_str());
            return 2;
        }
    }
    else
    {
        auto const ref = luaL_ref(L, LUA_REGISTRYINDEX);
        tcp->write(cmd, n, ref);
    }

    return 0;
}

auto build_ssl_context(
    std::string client_cert,
    std::string client_key,
    std::string client_key_password) -> boost::asio::ssl::context
{
    boost::asio::ssl::context ssl_context{boost::asio::ssl::context::method::tls_client};
    ssl_context.set_default_verify_paths();
    ssl_context.set_password_callback(
        [client_key_password](
            std::size_t const max_size,
            boost::asio::ssl::context::password_purpose purpose)
        {
            return client_key_password.size() <= max_size ? client_key_password : "";
        });

    if (not client_cert.empty())
    {
        ssl_context.use_certificate_file(client_cert, boost::asio::ssl::context::file_format::pem);
    }
    if (not client_key.empty())
    {
        ssl_context.use_private_key_file(client_key, boost::asio::ssl::context::file_format::pem);
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
            lua_pushstring(L, "message");
            pushircmsg(L, msg);
            safecall(L, "irc message", 2);
        }
        catch (irc_parse_error const &e)
        {
            lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
            lua_pushstring(L, "bad message");
            lua_pushnumber(L, static_cast<lua_Number>(e.code));
            safecall(L, "irc parse error", 2);
        }
    }
}

auto connect_thread(
    boost::asio::io_context &io_context,
    lua_State *const L,
    bool tls,
    std::string host,
    std::string port,
    std::string client_cert,
    std::string client_key,
    std::string client_key_password,
    std::string verify,
    int irc_cb) -> boost::asio::awaitable<void>
{
    LuaRef const irc_cb_ref{L, irc_cb};

    lua_pushnil(L); // this gets replaced with a pointer to the irc object later
    lua_pushcclosure(L, on_send_irc, 1);
    LuaRef const send_cb_ref{L, luaL_ref(L, LUA_REGISTRYINDEX)};

    try
    {
        auto const endpoints = co_await
            boost::asio::ip::tcp::resolver{io_context}
                .async_resolve({host, port}, boost::asio::use_awaitable);

        std::shared_ptr<irc_connection> irc;
        if (not tls)
        {
            auto plain_irc = std::make_shared<plain_irc_connection>(io_context, L);

            co_await boost::asio::async_connect(plain_irc->socket_, endpoints, boost::asio::use_awaitable);
            plain_irc->socket_.set_option(boost::asio::ip::tcp::no_delay(true));
            irc = std::move(plain_irc);
        }
        else
        {
            auto ssl_context = build_ssl_context(client_cert, client_key, client_key_password);
            auto tls_irc = std::make_shared<tls_irc_connection>(io_context, ssl_context, L);

            co_await boost::asio::async_connect(
                tls_irc->socket_.lowest_layer(),
                endpoints,
                boost::asio::use_awaitable);

            tls_irc->socket_.lowest_layer().set_option(boost::asio::ip::tcp::no_delay(true));
            if (not verify.empty())
            {
                tls_irc->socket_.set_verify_mode(boost::asio::ssl::verify_peer);
                tls_irc->socket_.set_verify_callback(boost::asio::ssl::host_name_verification(verify));
            }

            co_await tls_irc->socket_.async_handshake(
                boost::asio::ssl::stream_base::handshake_type::client,
                boost::asio::use_awaitable);

            irc = std::move(tls_irc);
        }

        irc_cb_ref.push();            // function
        lua_pushstring(L, "connect"); // argument 1
        send_cb_ref.push();           // argument 2
        lua_pushlightuserdata(L, irc.get());
        lua_setupvalue(L, -2, 1);
        safecall(L, "successful connect", 2);

        LineBuffer buff{32'000};
        for (;;)
        {
            auto const bytes_transferred = co_await irc->read_awaitable(buff.get_buffer());
            buff.add_bytes(
                bytes_transferred,
                [L, irc_cb](auto const line) { handle_read(line, L, irc_cb); });
        }
    }
    catch (std::exception &e)
    {
        // Remove send_callback's upvalue pointing to this object
        send_cb_ref.push();
        lua_pushnil(L);
        lua_setupvalue(L, -2, 1);
        lua_pop(L, 1);

        irc_cb_ref.push();
        lua_pushstring(L, "closed");
        lua_pushstring(L, e.what());
        safecall(L, "plain connect error", 2);
    }
}

}

auto start_irc(lua_State *const L) -> int
{
    auto const a = App::from_lua(L);

    auto const tls = lua_toboolean(L, 1);
    auto const host = luaL_checkstring(L, 2);
    auto const port = luaL_checkstring(L, 3);
    auto const client_cert = luaL_optlstring(L, 4, "", nullptr);
    auto const client_key = luaL_optlstring(L, 5, client_cert, nullptr);
    auto const client_key_password = luaL_optlstring(L, 6, "", nullptr);
    auto const verify = luaL_optlstring(L, 7, host, nullptr);
    luaL_checkany(L, 8); // callback
    lua_settop(L, 8);

    // consume the callback function and name it
    auto const irc_cb = luaL_ref(L, LUA_REGISTRYINDEX);

    boost::asio::co_spawn(
        a->io_context,
        connect_thread(a->io_context, L, tls, host, port, client_cert, client_key, client_key_password, verify, irc_cb),
        boost::asio::detached);

    return 0;
}

auto pushtags(lua_State *const L, std::vector<irctag> const &tags) -> void
{
    lua_createtable(L, 0, tags.size());
    for (auto &&tag : tags)
    {
        push_stringview(L, tag.key);
        if (tag.hasval())
        {
            push_stringview(L, tag.val);
        }
        else
        {
            lua_pushboolean(L, 1);
        }
        lua_settable(L, -3);
    }
}
