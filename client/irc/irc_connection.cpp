#include "irc_connection.hpp"

#include "socks.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

irc_connection::irc_connection(boost::asio::io_context& io_context, lua_State *L)
    : write_timer{io_context, boost::asio::steady_timer::time_point::max()}
    , L{L}
{
}

irc_connection::~irc_connection() {
    for (auto const ref : write_refs) {
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
    }
}

auto irc_connection::write(char const * const cmd, size_t const n, int const ref) -> void
{
    auto const idle = write_buffers.empty();
    write_buffers.emplace_back(cmd, n);
    write_refs.push_back(ref);
    if (idle)
    {
        write_timer.cancel_one();
    }
}

auto irc_connection::basic_connect(
    tcp_socket& socket,
    boost::asio::ip::tcp::resolver::results_type const& endpoints,
    std::string_view const socks_host,
    uint16_t const socks_port,
    std::string_view const socks_user,
    std::string_view const socks_pass
) -> boost::asio::awaitable<void>
{
    co_await boost::asio::async_connect(socket, endpoints, boost::asio::use_awaitable);
    socket.set_option(boost::asio::ip::tcp::no_delay(true));
    if (not socks_host.empty())
    {
        co_await socks5::async_connect(socket, socks_host, socks_port, socks_user, socks_pass, boost::asio::use_awaitable);
    }
}
