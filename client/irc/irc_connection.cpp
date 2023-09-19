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

auto irc_connection::write_thread(std::shared_ptr<irc_connection> irc) -> void
{
    auto const n = irc->write_buffers.size();
    if (n > 0)
    {
        // shared_ptr is captured here to ensure the buffers don't get
        // collected while asio is still using them
        irc->async_write([irc = std::move(irc), n](){
            // release written buffers
            for (auto i = n; i > 0; i--)
            {
                luaL_unref(irc->L, LUA_REGISTRYINDEX, irc->write_refs.front());
                irc->write_buffers.pop_front();
                irc->write_refs.pop_front();
            }
            irc_connection::write_thread(std::move(irc));
        });
    } else {
        irc->write_timer.async_wait(
            [weak = std::weak_ptr<irc_connection>{irc}](auto) {
                if (auto irc = weak.lock())
                {
                    irc_connection::write_thread(std::move(irc));
                }
            }
        );
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
        co_await socks5::async_connect(socket, socks_host, socks_port, boost::asio::use_awaitable);
    }
}
