#include "irc_connection.hpp"

#include <socks5.hpp>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

irc_connection::irc_connection(boost::asio::io_context& io_context, lua_State *L, std::shared_ptr<AnyStream> stream)
    : write_timer{io_context, boost::asio::steady_timer::time_point::max()}
    , L{L}
    , stream_{stream}
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
