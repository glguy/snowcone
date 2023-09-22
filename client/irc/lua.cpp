#include "lua.hpp"

#include "../app.hpp"
#include "../linebuffer.hpp"
#include "../safecall.hpp"
#include "../userdata.hpp"

#include "irc_connection.hpp"
#include "plain_connection.hpp"
#include "tls_connection.hpp"

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

auto l_close_irc(lua_State * const L) -> int
{
    auto const w = check_udata<std::weak_ptr<irc_connection>>(L, 1);
    if (w->expired())
    {
        luaL_error(L, "send to closed irc");
        return 0;
    }

    auto const error = w->lock()->close();
    if (error)
    {
        luaL_pushfail(L);
        lua_pushstring(L, error.message().c_str());
        return 2;
    }
    else
    {
        lua_pushboolean(L, 1);
        return 1;
    }
}

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
            {"close", l_close_irc},
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
    uint16_t port,
    std::string verify,
    std::string socks_host,
    uint16_t socks_port,
    int irc_cb
) -> boost::asio::awaitable<void>
{
    if (not socks_host.empty())
    {
        std::swap(host, socks_host);
        std::swap(port, socks_port);
    }

    try
    {
        {
            auto const endpoints = co_await
                boost::asio::ip::tcp::resolver{io_context}
                .async_resolve(host, std::to_string(port), boost::asio::use_awaitable);

            auto const fingerprint = co_await irc->connect(endpoints, verify, socks_host, socks_port);
            lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb); // function
            lua_pushstring(L, "CON"); // argument 1
            lua_pushlstring(L, fingerprint.data(), fingerprint.size()); // argument 2
            safecall(L, "successful connect", 2);
        }

        irc->write_thread();

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
    auto const socks_host = luaL_optlstring(L, 8, "", nullptr);
    auto const socks_port = luaL_optinteger(L, 9, 0);
    luaL_checkany(L, 10); // callback
    lua_settop(L, 10);

    // consume the callback function and name it
    auto const irc_cb = luaL_ref(L, LUA_REGISTRYINDEX);

    auto const a = App::from_lua(L);
    auto& io_context = a->io_context;
    std::shared_ptr<irc_connection> irc;

    if (tls)
    {
        auto ssl_context = build_ssl_context(client_cert, client_key, client_key_password);
        irc = std::make_shared<tls_irc_connection>(io_context, ssl_context, a->L);
    }
    else
    {
        irc = std::make_shared<plain_irc_connection>(io_context, a->L);
    }

    boost::asio::co_spawn(
        io_context,
        connect_thread(io_context, irc, a->L, host, port, verify, socks_host, socks_port, irc_cb),
        [L = a->L, irc_cb](std::exception_ptr e)
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
