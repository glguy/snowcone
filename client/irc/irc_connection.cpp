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
    write_buffers.clear();
    for (auto const ref : write_refs) {
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
    }
    write_refs.clear(); // the write thread checks for this
}

auto irc_connection::write_thread() -> boost::asio::awaitable<void>
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
    boost::asio::ip::tcp::socket& socket,
    boost::asio::ip::tcp::resolver::results_type const& endpoints,
    std::string_view socks_host,
    uint16_t socks_port
) -> boost::asio::awaitable<void>
{
    co_await boost::asio::async_connect(socket, endpoints, boost::asio::use_awaitable);
    socket.set_option(boost::asio::ip::tcp::no_delay(true));
    if (not socks_host.empty())
    {
        co_await socks_connect(socket, socks_host, socks_port);
    }
}
