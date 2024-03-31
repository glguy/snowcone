#include "app.hpp"

#include "applib.hpp"
#include "bracketed_paste.hpp"
#include "myncurses.h"
#include "safecall.hpp"
#include "strings.hpp"

extern "C"
{
#include <lua.h>
#include <lauxlib.h>
}

#include <ncurses.h>

#include <iostream>
#include <unistd.h>

static char app_key;

App::App()
    : io_context{}
    , stdin_poll{io_context, STDIN_FILENO}
    , winch{io_context, SIGWINCH}
{
    L = luaL_newstate();
    lua_pushlightuserdata(L, this);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &app_key);
}

App::~App()
{
    lua_close(L);
}

auto App::from_lua(lua_State *const L) -> App *
{
    lua_rawgetp(L, LUA_REGISTRYINDEX, &app_key);
    auto const a = reinterpret_cast<App*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return a;
}

namespace
{

auto do_mouse(lua_State* const L, int const y, int const x) -> void
{
    lua_pushinteger(L, y);
    lua_pushinteger(L, x);
    lua_callback(L, "on_mouse", 2);
}

auto do_keyboard(lua_State* const L, long const key) -> void
{
    lua_pushinteger(L, key);
    auto const success = lua_callback(L, "on_keyboard", 1);
    // fallback ^C
    if (not success and key == 3)
    {
        raise(SIGINT);
    }
}

auto do_paste(lua_State* const L, std::string_view const paste) -> void
{
    push_string(L, paste);
    lua_callback(L, "on_paste", 1);
}

} // namespace

auto App::winch_thread() -> boost::asio::awaitable<void>
{
    for (;;) {
        co_await winch.async_wait(boost::asio::use_awaitable);
        endwin();
        refresh();
        l_ncurses_resize(L);
        lua_callback(L, "on_resize", 0);
    }
}

auto App::stdin_thread() -> boost::asio::awaitable<void>
{
    std::string paste;
    bool in_paste = false;
    mbstate_t mbstate{};

    for(;;) {
        co_await stdin_poll.async_wait(
            boost::asio::posix::stream_descriptor::wait_read,
            boost::asio::use_awaitable);

        for (int key; ERR != (key = getch());)
        {
            if (in_paste)
            {
                if (BracketedPaste::end_paste == key)
                {
                    do_paste(L, paste);
                    paste.clear();
                    in_paste = false;
                }
                else
                {
                    paste.push_back(key);
                }
            }
            else if (key == '\x1b')
            {
                key = getch();
                do_keyboard(L, ERR == key ? '\x1b' : -key);
            }
            else if (KEY_MOUSE == key)
            {
                MEVENT ev;
                getmouse(&ev);
                if (ev.bstate == BUTTON1_CLICKED)
                {
                    do_mouse(L, ev.y, ev.x);
                }
            }
            else if (BracketedPaste::start_paste == key)
            {
                in_paste = true;
            }
            else if (BracketedPaste::focus_gained == key)
            {
                do_keyboard(L, -KEY_RESUME);
            }
            else if (BracketedPaste::focus_lost == key)
            {
                do_keyboard(L, -KEY_EXIT);
            }
            else if (key > 0xff)
            {
                do_keyboard(L, -key);
            }
            else if (isascii(key))
            {
                do_keyboard(L, key);
            }
            else
            {
                char const c = key;
                wchar_t code;
                size_t const r = mbrtowc(&code, &c, 1, &mbstate);
                if (r < (size_t)-2)
                {
                    do_keyboard(L, code);
                }
            }
        }
    }
}

auto App::startup() -> void
{
    boost::asio::co_spawn(io_context, stdin_thread(), boost::asio::detached);
    boost::asio::co_spawn(io_context, winch_thread(), boost::asio::detached);
    io_context.run();
}

auto App::shutdown() -> void
{
    stdin_poll.close();
    winch.cancel();
}
