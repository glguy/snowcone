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

void app::do_command(char const* line, uv_stream_t* console)
{
    this->console = console;

    if (*line == '/')
    {
        line++;
        if (!strcmp(line, "reload"))
        {
            load_logic(L, cfg->lua_filename);
        }
        else
        {
            char const* msg = "Unknown command\n";
            to_write(console, msg, strlen(msg));
        }
    }
    else
    {
        lua_pushstring(L, line);
        lua_callback(L, "on_input");
    }
    
    this->console = nullptr;
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

void app::do_dns(addrinfo* ai)
{
    AddrInfo addrinfos {ai};
    lua_newtable(L); // raw addresses
    lua_newtable(L); // printable addresses
    lua_Integer i = 0;

    for (auto const& a : addrinfos) {
        uv_getnameinfo_t req;
        uvok(uv_getnameinfo(&loop, &req, nullptr, a.ai_addr, NI_NUMERICHOST));

        i++;
        
        lua_pushstring(L, req.host);
        lua_rawseti(L, -3, i);

        switch (a.ai_family) {
            default: lua_pushstring(L, ""); break;
            case PF_INET: {
                auto sin = reinterpret_cast<sockaddr_in const*>(a.ai_addr);
                lua_pushlstring(L, reinterpret_cast<char const*>(&sin->sin_addr), sizeof sin->sin_addr);
                break;
            }
            case PF_INET6: {
                auto sin6 = reinterpret_cast<sockaddr_in6 const*>(a.ai_addr);
                lua_pushlstring(L, reinterpret_cast<char const*>(&sin6->sin6_addr), sizeof sin6->sin6_addr);
                break;
            }
        }
        lua_rawseti(L, -2, i);
    }
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
