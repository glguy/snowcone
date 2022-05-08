#include "app.hpp"

#include "applib.hpp"
#include "uv.hpp"
#include "uvaddrinfo.hpp"
#include "write.hpp"

#include <ircmsg.hpp>

extern "C" {
#include <myncurses.h>
#if HAS_GEOIP
#include <mygeoip.h>
#endif
#include <mybase64.h>

#include "lauxlib.h"
#include "lualib.h"
}

#include <ncurses.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <locale>
#include <netdb.h>
#include <signal.h>
#include <stdexcept>
#include <unistd.h>

void app::init()
{
    uvok(uv_loop_init(&loop));
    uvok(uv_poll_init(&loop, &input, STDIN_FILENO));
    uvok(uv_signal_init(&loop, &winch));
    uvok(uv_timer_init(&loop, &reconnect));

    L = luaL_newstate();
    if (nullptr == L) throw std::runtime_error("failed to create lua");

    app_ref(L) = this;

    prepare_globals(L, cfg);
    load_logic(L, cfg->lua_filename);
}

void app::destroy()
{
    lua_close(L);
    uvok(uv_loop_close(&loop));
}

void app::do_keyboard(long key)
{
    lua_pushinteger(L, key);
    lua_callback(L, "on_keyboard");
}

void app::set_irc(uv_stream_t *irc)
{
    this->irc = irc;
    lua_callback(L, "on_connect");
}

void app::clear_irc()
{
    irc = nullptr;
    lua_callback(L, "on_disconnect");
}

void app::set_window_size()
{
    l_ncurses_resize(L);
}

void app::do_irc(ircmsg const& msg)
{
    pushircmsg(L, msg);
    lua_callback(L, "on_irc");
}

void app::do_irc_err(char const* msg)
{
    lua_pushstring(L, msg);
    lua_callback(L, "on_irc_err");
}

void app::do_mouse(int y, int x)
{
    lua_pushinteger(L, y);
    lua_pushinteger(L, x);
    lua_callback(L, "on_mouse");
}
