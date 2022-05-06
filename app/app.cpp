#include "app.hpp"

#include "applib.hpp"
#include "uv.hpp"
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

void app::do_dns(addrinfo const* ai)
{
    char buffer[INET6_ADDRSTRLEN];
    lua_newtable(L); // raw addresses
    lua_newtable(L); // printable addresses
    lua_Integer i = 0;
    while (ai) {
        int r = getnameinfo(ai->ai_addr, ai->ai_addrlen, buffer, sizeof buffer, nullptr, 0, NI_NUMERICHOST);
        if (0 == r){
            i++;
            lua_pushstring(L, buffer);
            lua_rawseti(L, -3, i);

            switch (ai->ai_family) {
                default: lua_pushstring(L, ""); break;
                case PF_INET: {
                    struct sockaddr_in *sin = (struct sockaddr_in *)ai->ai_addr;
                    lua_pushlstring(L, (char*)&sin->sin_addr, sizeof sin->sin_addr);
                    break;
                }
                case PF_INET6: {
                    struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)ai->ai_addr;
                    lua_pushlstring(L, (char*)&sin6->sin6_addr, sizeof sin6->sin6_addr);
                    break;
                }
            }
            lua_rawseti(L, -2, i);
        } else {
            // I don't know when this could actually fail
            std::cerr << "getnameinfo: " << gai_strerror(r) << std::endl;
        }
        ai = ai->ai_next;
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
