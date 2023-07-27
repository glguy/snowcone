/**
 * @file app.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Core application state
 * 
 */

#pragma once

struct configuration;
struct ircmsg;

extern "C" {
#include "lua.h"
}
#include <uv.h>

#include <chrono>
#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

using namespace std::chrono_literals;

struct app
{
    lua_State *L;
    configuration const& cfg;
    uv_stream_t *irc;
    uv_loop_t loop;
    uv_poll_t input;
    uv_signal_t winch;
    uv_timer_t reconnect;
    bool closing;
    std::chrono::seconds reconnect_delay;
    std::optional<std::string> paste;

    inline static auto app_cell(lua_State* const L) -> app*& {
        return *static_cast<app**>(lua_getextraspace(L));
    }

public:
    app(configuration const& cfg)
    : L {}
    , cfg {cfg}
    , irc {}
    , loop {}
    , input {}
    , winch {}
    , closing {false}
    , reconnect_delay(0s)
    , paste {}
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
    void do_paste();
    void set_irc(uv_stream_t* stream);
    void clear_irc();
    void set_window_size();
    void do_irc(ircmsg const&);
    void do_irc_err(std::string_view);
    bool send_irc(char const*, std::size_t, int ref);
    bool close_irc();
    void run();
    std::chrono::seconds next_delay();
    void reset_delay();

    static app* from_loop(uv_loop_t* loop) {
        return static_cast<app*>(loop->data);
    }
    static app* from_lua(lua_State* L) {
        return app_cell(L);
    }
    void to_lua(lua_State* L) {
        app_cell(L) = this;
    }
};
