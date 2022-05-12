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
#include <string_view>
#include <vector>

struct app
{
    lua_State *L;
    configuration *cfg;
    uv_stream_t *irc;
    uv_loop_t loop;
    uv_poll_t input;
    uv_signal_t winch;
    uv_timer_t reconnect;
    bool closing;

public:
    app(configuration * cfg)
    : L {}
    , cfg {cfg}
    , irc {}
    , loop {}
    , input {}
    , winch {}
    , closing {false}
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

    void do_mouse(int y, int x);
    void do_keyboard(long key);
    void set_irc(uv_stream_t* stream);
    void clear_irc();
    void set_window_size();
    void do_irc(ircmsg const&);
    void do_irc_err(std::string_view);
    bool send_irc(char const*, std::size_t, int ref);
    bool close_irc();
    void run();

    static app* from_loop(uv_loop_t* loop) {
        return reinterpret_cast<app*>(loop->data);
    }
    static app* from_lua(lua_State* L) {
        return *static_cast<app**>(lua_getextraspace(L));
    }
    void to_lua(lua_State* L) {
        *static_cast<app**>(lua_getextraspace(L)) = this;
    }
};
