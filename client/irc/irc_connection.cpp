#include "irc_connection.hpp"

#include <socks5.hpp>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

irc_connection::irc_connection(boost::asio::io_context& io_context, lua_State *L, int irc_cb, std::shared_ptr<AnyStream> stream)
    : write_timer{io_context, boost::asio::steady_timer::time_point::max()}
    , L{L}
    , irc_cb_{irc_cb}
    , stream_{stream}
{
}

irc_connection::~irc_connection() {
    for (auto const ref : write_refs) {
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
    }
    luaL_unref(L, LUA_REGISTRYINDEX, irc_cb_);
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
