#pragma once

#include <string>

#include <uv.h>

struct lua_State;

struct App
{
    uv_loop_t loop;
    lua_State *L;
    uv_poll_t stdin_poll;
    uv_signal_t winch_signal;
    std::string paste;
    bool in_paste = false;
    mbstate_t mbstate{};

    App();
    ~App();

    static auto from_loop(uv_loop_t const *loop) -> App *;
    static auto from_lua(lua_State *) -> App *;

    auto do_mouse(int y, int x) -> void;
    auto do_keyboard(long key) -> void;
    auto do_paste() -> void;

    auto startup() -> void;
    auto shutdown() -> void;

    static auto on_stdin(uv_poll_t *handle, int status, int events) -> void;
    static auto on_winch(uv_signal_t* handle, int signum) -> void;
};
