#include "app.hpp"

#include "applib.hpp"
#include "bracketed_paste.hpp"
#include "myncurses.h"
#include "safecall.hpp"

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <ncurses.h>
#include <iostream>
#include <unistd.h>

App::App()
    : io_context{}
    , stdin_poll{io_context, STDIN_FILENO}
{
    L = luaL_newstate();
    *reinterpret_cast<App **>(lua_getextraspace(L)) = this;
}

App::~App()
{
    lua_close(L);
}

auto App::from_lua(lua_State *const L) -> App *
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
    if (not success and key == 3)
    {
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

namespace
{
    auto on_stdin(App *const a) -> void
    {
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
                endwin();
                refresh();
                l_ncurses_resize(a->L);
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

    auto stdin_poll_loop(App *const a) -> void
    {
        a->stdin_poll.async_wait(boost::asio::posix::stream_descriptor::wait_read, [a](auto const error)
                                 {
        if (!error) {
            on_stdin(a);
            stdin_poll_loop(a);
        } });
    }
}

auto App::startup() -> void
{
    stdin_poll_loop(this);
    io_context.run();
}

auto App::shutdown() -> void
{
    stdin_poll.close();
}
