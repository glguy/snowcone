/**
 * @file app.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Core application state
 * 
 */

#pragma once

#include "uv.hpp"
#include "configuration.hpp"

#include <ircmsg.hpp>

extern "C" {
#include <lua.h>
}
#include <uv.h>

#include <cstdlib>
#include <vector>

struct app
{
    lua_State *L;
    struct configuration *cfg;
    uv_stream_t *irc;
    uv_loop_t loop;
    uv_poll_t input;
    uv_signal_t winch;
    uv_timer_t reconnect;
    bool closing;

public:
    app(configuration * cfg)
    : cfg(cfg)
    , irc(nullptr)
    , loop()
    , input()
    , winch()
    , closing(false)
    {
        loop.data = this;
    }

    app(app const&) = delete;
    app(app&&) = delete;
    app& operator=(app const&) = delete;
    app& operator=(app &&) = delete;

    void init();
    void shutdown();
    void destroy();

    void do_mouse(int x, int y);
    void do_keyboard(long);
    void set_irc(uv_stream_t* stream);
    void clear_irc();
    void set_window_size();
    void do_irc(ircmsg const&);
    void do_irc_err(char const*);
    bool send_irc(char const*, size_t len);
    void run();

    static app* from_loop(uv_loop_t* loop) {
        return reinterpret_cast<app*>(loop->data);
    }
};

inline app*& app_ref(lua_State* L) {
    return *static_cast<app**>(lua_getextraspace(L));
}
