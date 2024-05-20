#include "lua.hpp"
#include "../app.hpp"
#include "../linebuffer.hpp"
#include "../safecall.hpp"
#include "../strings.hpp"
#include "../userdata.hpp"
#include "irc_connection.hpp"

#include <pkey.hpp>
#include <x509.hpp>

#include <ircmsg.hpp>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <charconv> // from_chars
#include <fcntl.h>
#include <memory>
#include <string>
#include <system_error>
#include <variant>

namespace {

using namespace std::literals::string_view_literals;

using tcp_type = boost::asio::ip::tcp::socket;
using tls_type = boost::asio::ssl::stream<tcp_type>;

auto l_close_irc(lua_State* const L) -> int
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

auto l_send_irc(lua_State* const L) -> int
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

auto pushirc(lua_State* const L, std::weak_ptr<irc_connection> const irc) -> void
{
    auto const w = new_udata<std::weak_ptr<irc_connection>>(L, 1, [L]() {
        auto constexpr l_gc = [](lua_State* const L) -> int {
            auto const w = check_udata<std::weak_ptr<irc_connection>>(L, 1);
            std::destroy_at(w);
            return 0;
        };

        luaL_Reg const MT[]{
            {"__gc", l_gc},
            {},
        };
        luaL_setfuncs(L, MT, 0);

        // Setup class methods for IRC objects
        luaL_Reg const Methods[]{
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

// Get the next complete line skipping over empty lines
auto get_nonempty_line(LineBuffer& buff) -> char*
{
    char* line;
    while ((line = buff.next_line()))
    {
        while (*line == ' ')
        {
            line++;
        }
        if ('\0' != *line)
        {
            break;
        }
    }
    return line;
}

auto session_thread(
    boost::asio::io_context& io_context,
    int const irc_cb,
    std::shared_ptr<irc_connection> const irc,
    Settings settings
) -> boost::asio::awaitable<void>
{
    auto const L = irc->get_lua();

    {
        auto const fingerprint = co_await irc->connect(std::move(settings));

        lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
        push_string(L, "CON"sv);
        push_string(L, fingerprint);
        safecall(L, "successful connect", 2);
    }

    for (LineBuffer buff{irc_connection::irc_buffer_size};;)
    {
        auto const target = buff.get_buffer();
        if (target.size() == 0)
        {
            throw std::runtime_error{"line buffer full"};
        }

        buff.add_bytes(co_await irc->get_stream().async_read_some(target, boost::asio::use_awaitable));
        for (auto line = get_nonempty_line(buff); nullptr != line; /* empty */)
        {
            auto const msg = parse_irc_message(line); // might throw
            line = get_nonempty_line(buff); // pre-load next line

            lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
            push_string(L, "MSG"sv);
            pushircmsg(L, msg);
            lua_pushboolean(L, nullptr == line); // draw on last line
            safecall(L, "irc message", 3);
        }
    }
}

} // namespace

auto l_start_irc(lua_State* const L) -> int
{
    auto const tls = lua_toboolean(L, 1);
    auto const host = luaL_checkstring(L, 2);
    auto const port = luaL_checkinteger(L, 3);
    auto const client_cert = luaL_opt(L, myopenssl::check_x509, 4, nullptr);
    auto const client_key = luaL_opt(L, myopenssl::check_pkey, 5, nullptr);
    auto const verify = luaL_optlstring(L, 6, host, nullptr);
    auto const sni = luaL_optlstring(L, 7, host, nullptr);
    auto const socks_host = luaL_optlstring(L, 8, "", nullptr);
    auto const socks_port = luaL_optinteger(L, 9, 0);
    auto const socks_user = luaL_optlstring(L, 10, "", nullptr);
    auto const socks_pass = luaL_optlstring(L, 11, "", nullptr);
    luaL_checkany(L, 12); // callback
    lua_settop(L, 12);
    luaL_argcheck(L, 1 <= port && port <= 0xffff, 3, "port out of range");
    luaL_argcheck(L, 0 <= socks_port && socks_port <= 0xffff, 9, "port out of range");

    auto const irc_cb = luaL_ref(L, LUA_REGISTRYINDEX);

    Settings settings = {
        .tls = static_cast<bool>(tls),
        .host = host,
        .port = static_cast<std::uint16_t>(port),
        .client_cert = client_cert,
        .client_key = client_key,
        .verify = verify,
        .sni = sni,
        .socks_host = socks_host,
        .socks_port = static_cast<std::uint16_t>(socks_port),
        .socks_user = socks_user,
        .socks_pass = socks_pass,
        .buffer_size = irc_connection::irc_buffer_size,
    };

    auto& a = *App::from_lua(L);
    auto& io_context = a.get_executor();
    auto const LMain = a.get_lua();

    auto const irc = irc_connection::create(io_context, LMain);
    pushirc(L, irc);

    boost::asio::co_spawn(
        io_context, session_thread(io_context, irc_cb, irc, std::move(settings)),
        [L = LMain, irc_cb](std::exception_ptr const e) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, irc_cb);
            luaL_unref(L, LUA_REGISTRYINDEX, irc_cb);
            push_string(L, "END"sv);

            try
            {
                std::rethrow_exception(e);
            }
            catch (std::exception const& ex)
            {
                push_string(L, ex.what());
            }
            catch (...)
            {
                lua_pushnil(L);
            }

            safecall(L, "end of connection", 2);
        }
    );

    return 1;
}

auto pushircmsg(lua_State* const L, ircmsg const& msg) -> void
{
    lua_createtable(L, msg.args.size(), 3);
    pushtags(L, msg.tags);
    lua_setfield(L, -2, "tags");

    if (not msg.source.empty())
    {
        push_string(L, msg.source);
        lua_setfield(L, -2, "source");
    }

    lua_Integer code;
    auto const [last, ec] = std::from_chars(msg.command.begin(), msg.command.end(), code);
    if (ec == std::errc{} && last == msg.command.end())
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

auto pushtags(lua_State* const L, std::vector<irctag> const& tags) -> void
{
    lua_createtable(L, 0, tags.size());
    for (auto&& tag : tags)
    {
        push_string(L, tag.key);
        push_string(L, tag.val);
        lua_settable(L, -3);
    }
}

template <>
char const* udata_name<std::weak_ptr<irc_connection>> = "irc_connection";
