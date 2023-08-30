#include "irc.hpp"

#include "app.hpp"
#include "linebuffer.hpp"
#include "safecall.hpp"
#include "userdata.hpp"

#include <ircmsg.hpp>

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <charconv> // from_chars
#include <deque>
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
    boost::asio::steady_timer write_timer;
    lua_State *L;

    std::deque<boost::asio::const_buffer> write_buffers;
    std::deque<int> write_refs;

public:
    irc_connection(boost::asio::io_context &io_context, lua_State *L)
        : io_context{io_context}
        , write_timer{io_context, boost::asio::steady_timer::time_point::max()}
        , L{L}
    {
    }

    virtual ~irc_connection() {
        write_buffers.clear();
        for (auto const ref : write_refs) {
            luaL_unref(L, LUA_REGISTRYINDEX, ref);
        }
        write_refs.clear(); // the write thread checks for this
    }

    auto write_thread() -> boost::asio::awaitable<void>
    {
        for(;;)
        {
            if (write_buffers.empty()) {
                // wait and ignore the cancellation errors
                boost::system::error_code ec;
                co_await write_timer.async_wait(
                    boost::asio::redirect_error(boost::asio::use_awaitable, ec));

                if (write_buffers.empty()) {
                    // We got canceled by the destructor - shows over
                    co_return;
                }
            }

            auto n = write_buffers.size();
            co_await write_awaitable();

            // release written buffers
            for (; n > 0; n--)
            {
                luaL_unref(L, LUA_REGISTRYINDEX, write_refs.front());
                write_buffers.pop_front();
                write_refs.pop_front();
            }
        }
    }

    auto write(char const * const cmd, size_t const n, int const ref) -> void
    {
        auto const idle = write_buffers.empty();
        write_buffers.emplace_back(cmd, n);
        write_refs.push_back(ref);
        if (idle)
        {
            write_timer.cancel_one();
        }
    }

    auto virtual write_awaitable() -> boost::asio::awaitable<std::size_t> = 0;
    auto virtual read_awaitable(boost::asio::mutable_buffers_1 const& buffers) -> boost::asio::awaitable<std::size_t> = 0;
    auto virtual connect(
        boost::asio::ip::tcp::resolver::results_type const&,
        std::string const&
    ) -> boost::asio::awaitable<void> = 0;
};

class plain_irc_connection final : public irc_connection
{
public:
    boost::asio::ip::tcp::socket socket_;

    plain_irc_connection(boost::asio::io_context &io_context, lua_State *const L)
        : irc_connection{io_context, L}, socket_{io_context}
    {
    }

    auto write_awaitable() -> boost::asio::awaitable<std::size_t> override
    {
        return boost::asio::async_write(socket_, write_buffers, boost::asio::use_awaitable);
    }

    auto read_awaitable(
        boost::asio::mutable_buffers_1 const& buffers
    ) -> boost::asio::awaitable<std::size_t> override
    {
        return socket_.async_read_some(buffers, boost::asio::use_awaitable);
    }

    auto connect(
        boost::asio::ip::tcp::resolver::results_type const& endpoints,
        std::string const&
    ) -> boost::asio::awaitable<void> override
    {
        co_await boost::asio::async_connect(socket_, endpoints, boost::asio::use_awaitable);
        socket_.set_option(boost::asio::ip::tcp::no_delay(true));    
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

    auto write_awaitable() -> boost::asio::awaitable<std::size_t> override
    {
        return boost::asio::async_write(socket_, write_buffers, boost::asio::use_awaitable);
    }

    auto read_awaitable(
        boost::asio::mutable_buffers_1 const& buffers
    ) -> boost::asio::awaitable<std::size_t> override
    {
        return socket_.async_read_some(buffers, boost::asio::use_awaitable);
    }

    auto connect(
        boost::asio::ip::tcp::resolver::results_type const& endpoints,
        std::string const& verify
    ) -> boost::asio::awaitable<void> override
    {
        co_await boost::asio::async_connect(socket_.lowest_layer(), endpoints, boost::asio::use_awaitable);
        socket_.lowest_layer().set_option(boost::asio::ip::tcp::no_delay(true));
        if (not verify.empty())
        {
            socket_.set_verify_mode(boost::asio::ssl::verify_peer);
            socket_.set_verify_callback(boost::asio::ssl::host_name_verification(verify));
        }
        co_await socket_.async_handshake(socket_.client, boost::asio::use_awaitable);
    }
};

auto l_send_irc(lua_State * const L) -> int
{
    auto const w = check_udata<std::weak_ptr<irc_connection>>(L, 1);
    if (w->expired())
    {
        luaL_error(L, "send to closed irc");
        return 0;
    }

    // Wait until after luaL_error to start putting things on the
    // stack that have destructors

    size_t n;
    auto const cmd = luaL_checklstring(L, 2, &n);
    lua_settop(L, 2);
    auto const ref = luaL_ref(L, LUA_REGISTRYINDEX);

    w->lock()->write(cmd, n, ref);
    return 0;
}

auto build_ssl_context(
    std::string const& client_cert,
    std::string const& client_key,
    std::string const& client_key_password
) -> boost::asio::ssl::context
{
    boost::asio::ssl::context ssl_context{boost::asio::ssl::context::method::tls_client};
    ssl_context.set_default_verify_paths();
    if (not client_key_password.empty())
    {
        ssl_context.set_password_callback(
            [client_key_password](
                std::size_t const max_size,
                boost::asio::ssl::context::password_purpose purpose)
            {
                return client_key_password.size() <= max_size ? client_key_password : "";
            });
    }
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

auto pushirc(lua_State * const L, std::shared_ptr<irc_connection> irc) -> void
{
    auto const w = new_udata<std::weak_ptr<irc_connection>>(L, 1, [L]() {
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
            {}
        };
        luaL_setfuncs(L, MT, 0);
        luaL_newlib(L, Methods);
        lua_setfield(L, -2, "__index");
    });
    new (w) std::weak_ptr{irc};
}

auto connect_thread(
    boost::asio::io_context &io_context,
    std::shared_ptr<irc_connection> irc,
    lua_State *const L,
    std::string host,
    std::string port,
    std::string verify,
    int irc_cb
) -> boost::asio::awaitable<void>
{
    try
    {
        {
            auto const endpoints = co_await
            boost::asio::ip::tcp::resolver{io_context}
                .async_resolve(host, port, boost::asio::use_awaitable);
            co_await irc->connect(endpoints, verify);
        }

        boost::asio::co_spawn(io_context, irc->write_thread(), boost::asio::detached);

        lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb); // function
        lua_pushstring(L, "connect"); // argument 1
        safecall(L, "successful connect", 1);

        for (LineBuffer buff{32'000};;)
        {
            buff.add_bytes(
                co_await irc->read_awaitable(buff.get_buffer()),
                [L, irc_cb](auto const line) { handle_read(line, L, irc_cb); });
        }
    }
    catch (std::exception &e)
    {
        lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
        lua_pushstring(L, "closed");
        lua_pushstring(L, e.what());
        safecall(L, "plain connect error", 2);
    }
}

} // namespace

auto l_start_irc(lua_State *const L) -> int
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

    std::shared_ptr<irc_connection> irc;
    if (tls)
    {
        auto ssl_context = build_ssl_context(client_cert, client_key, client_key_password);
        irc = std::make_shared<tls_irc_connection>(a->io_context, ssl_context, L);
    }
    else
    {
        irc = std::make_shared<plain_irc_connection>(a->io_context, L);
    }

    boost::asio::co_spawn(
        a->io_context,
        connect_thread(a->io_context, irc, L, host, port, verify, irc_cb),
        [L, irc_cb](std::exception_ptr e)
        {
            luaL_unref(L, LUA_REGISTRYINDEX, irc_cb);
        });

    pushirc(L, irc);

    return 1;
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
template<> char const* udata_name<std::weak_ptr<irc_connection>> = "irc_connection";
