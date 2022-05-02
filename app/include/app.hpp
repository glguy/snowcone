#pragma once

#include <netdb.h>
#include <stdlib.h>
#include <unistd.h>
#include <uv.h>

#include <vector>

extern "C" {
#include <lua.h>
}
#include <ircmsg.hpp>

#include "uv.hpp"
#include "configuration.hpp"

struct app
{
    lua_State *L;
    struct configuration *cfg;
    uv_stream_t *console;
    uv_stream_t *irc;
    uv_loop_t loop;
    uv_poll_t input;
    uv_signal_t winch;
    std::vector<uv_tcp_t> listeners;
    bool closing;

public:
    app(configuration * cfg)
    : cfg(cfg)
    , console(nullptr)
    , irc(nullptr)
    , loop()
    , input()
    , winch()
    , listeners()
    , closing(false)
    {
        loop.data = this;
    }

    app(app const&) = delete;
    app& operator=(app const&) = delete;

    void init();
    void destroy();

    void do_command(char const* line, uv_stream_t* console);
    void do_mouse(int x, int y);
    void do_keyboard(long);
    void set_irc(uv_stream_t* stream);
    void clear_irc();
    void set_window_size();
    void do_irc(ircmsg const&);
    void do_irc_err(char const*);

    void do_dns(addrinfo const* ai);
};

inline app*& app_ref(lua_State *L) {
    return *static_cast<app**>(lua_getextraspace(L));
}
