#include "irc_connection.hpp"

#include <socks5.hpp>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include "../net/connect.hpp"

irc_connection::irc_connection(boost::asio::io_context& io_context, lua_State *L)
    : write_timer{io_context, boost::asio::steady_timer::time_point::max()}
    , L{L}
    , stream_{boost::asio::ip::tcp::socket{io_context}}
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
