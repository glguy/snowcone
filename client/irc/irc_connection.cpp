#include "irc_connection.hpp"

#include <socks5.hpp>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include "../net/connect.hpp"

irc_connection::irc_connection(
    Private,
    boost::asio::io_context& io_context,
    lua_State* const L
)
    : stream_{boost::asio::ip::tcp::socket{io_context}}
    , L{L}
    , writing_{false}
{
}

irc_connection::~irc_connection()
{
    for (auto const ref : write_refs)
    {
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
    }
}

auto irc_connection::write(std::string_view const cmd, int const ref) -> void
{
    write_buffers.emplace_back(cmd.data(), cmd.size());
    write_refs.emplace_back(ref);
    if (not writing_)
    {
        writing_ = true;
        write_actual();
    }
}

auto irc_connection::write_actual() -> void
{
    boost::asio::async_write(
        stream_,
        write_buffers,
        [weak = weak_from_this(), L = L, refs = std::move(write_refs)]
        (boost::system::error_code const& error, std::size_t)
        {
            for (auto const ref : refs)
            {
                luaL_unref(L, LUA_REGISTRYINDEX, ref);
            }
            if (not error)
            {
                if (auto const self = weak.lock())
                {
                    if (self->write_buffers.empty())
                    {
                        self->writing_ = false;
                    }
                    else
                    {
                        self->write_actual();
                    }
                }
            }
        });
    write_buffers.clear();
    write_refs.clear();
}

auto irc_connection::close() -> void
{
    stream_.close();
}
