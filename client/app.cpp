#include "app.hpp"

#include "applib.hpp"
#include "bracketed_paste.hpp"
#include "myncurses.h"
#include "safecall.hpp"
#include "uv.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <ncurses.h>

#include <unistd.h>

App::App() {
    uv_loop_init(&loop);
    loop.data = this;
    uv_signal_init(&loop, &winch_signal);
    uv_poll_init(&loop, &stdin_poll, STDIN_FILENO);

    L = luaL_newstate();
    *reinterpret_cast<App **>(lua_getextraspace(L)) = this;
}

App::~App() {
    lua_close(L);
    uv_loop_close(&loop);
}

auto App::from_loop(uv_loop_t const *loop) -> App *
{
    return reinterpret_cast<App *>(loop->data);
}

auto App::from_lua(lua_State* const L) -> App *
{
    return *reinterpret_cast<App **>(lua_getextraspace(L));
}

auto App::do_mouse(int y, int x) -> void
{
    lua_pushinteger(L, y);
    lua_pushinteger(L, x);
    lua_callback(L, "on_mouse");
}

auto App::do_keyboard(long key) -> void
{
    lua_pushinteger(L, key);
    auto const success = lua_callback(L, "on_keyboard");
    // fallback ^C
    if (not success and key == 3) {
        raise(SIGINT);
    }
}

auto App::do_paste() -> void
{
    lua_pushlstring(L, paste.data(), paste.size());
    paste.clear();
    in_paste = false;
    lua_callback(L, "on_paste");
}

auto App::startup() -> void
{
    uv_poll_start(&stdin_poll, UV_READABLE, on_stdin);
    uv_signal_start(&winch_signal, on_winch, SIGWINCH);
    uv_run(&loop, UV_RUN_DEFAULT);
}

auto App::shutdown() -> void
{
    uv_close_xx(&stdin_poll);
    uv_close_xx(&winch_signal);
}

auto App::on_winch(uv_signal_t* handle, int signum) -> void
{
    endwin();
    refresh();
    auto const app = App::from_loop(handle->loop);
    l_ncurses_resize(app->L);
}

auto App::on_stdin(uv_poll_t *handle, int status, int events) -> void
{
    if (status != 0)
        return;

    auto const a = App::from_loop(handle->loop);

    for (int key; ERR != (key = getch());)
    {
        if (a->in_paste)
        {
            if (BracketedPaste::end_paste == key)
            {
                a->do_paste();
            }
            else
            {
                a->paste.push_back(key);
            }
        }
        else if (key == '\x1b')
        {
            key = getch();
            a->do_keyboard(ERR == key ? '\x1b' : -key);
        }
        else if (KEY_MOUSE == key)
        {
            MEVENT ev;
            getmouse(&ev);
            if (ev.bstate == BUTTON1_CLICKED)
            {
                a->do_mouse(ev.y, ev.x);
            }
        }
        else if (KEY_RESIZE == key)
        {
        }
        else if (BracketedPaste::start_paste == key)
        {
            a->in_paste = true;
        }
        else if (key > 0xff)
        {
            a->do_keyboard(-key);
        }
        else if (isascii(key))
        {
            a->do_keyboard(key);
        }
        else
        {
            char const c = key;
            wchar_t code;
            size_t const r = mbrtowc(&code, &c, 1, &a->mbstate);
            if (r < (size_t)-2)
            {
                a->do_keyboard(code);
            }
        }
    }
}
